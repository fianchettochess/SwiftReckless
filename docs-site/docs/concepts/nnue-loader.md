# NNUE Network Loader

`RecklessNetworkLoader` downloads, verifies, and provisions the Reckless NNUE
evaluation network. It must complete before `RecklessEngine` is created.

!!! warning "Net must come before engine"
    `RecklessEngine.init(networkDirectory:)` returns `nil` — not a crash, but a
    clean failure — when the NNUE net is absent. Always `await ensure(in:)` first.

## The network

Reckless v0.9 uses a single NNUE network:

| Property | Value |
|---|---|
| Filename | `v54-5478683c.nnue` |
| Size | ~60 MB |
| SHA-256 | `5478683cb1bababde29ae8f29468a99846726548fc6a0ed54cac40ab6d38efbf` |
| Download source | [RecklessNetworks releases](https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/) |

The filename encodes the first 8 hex characters of the SHA-256 (`5478683c`), the
same convention Stockfish uses. The loader verifies the **full** SHA-256 digest
after downloading on every supported platform (see
[SHA-256 verification](#sha-256-verification-and-cross-platform-crypto)).

The network spec is declared as a constant:

```swift
public static let network = RecklessNetworkLoader.Network(
    filename: "v54-5478683c.nnue",
    sha256: "5478683cb1bababde29ae8f29468a99846726548fc6a0ed54cac40ab6d38efbf",
    downloadURL: URL(string: "https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/v54-5478683c.nnue")!
)
```

## The `Network` type

```swift
public struct RecklessNetworkLoader.Network: Sendable {
    public let filename: String
    public let sha256: String          // full SHA-256 hex string
    public let downloadURL: URL
    public var shaPrefix: String       // first 8 hex chars, matches filename segment
}
```

## The loader

```swift
public struct RecklessNetworkLoader: Sendable {
    public init()

    @discardableResult
    public func ensure(
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL
}
```

`ensure(in:progress:)`:

1. Creates `directory` if it does not exist.
2. If `v54-5478683c.nnue` is already present and passes complete SHA-256 verification,
   returns
   immediately — **no download, no network access**.
3. If missing or invalid: downloads to a temporary location, verifies the SHA-256
   digest (see [cross-platform note](#sha-256-verification-and-cross-platform-crypto)),
   and atomically moves the file into place.
4. Returns the `URL` of the verified network file inside `directory`.

The operation is **idempotent**. A warm launch with a valid net is a fast
checksum-only no-op.

## Progress

```swift
public struct RecklessNetworkLoader.Progress: Sendable {
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public var fractionCompleted: Double?   // nil when server omits Content-Length
}
```

The progress closure is invoked on the download task thread. It is only called when
a download is actually in progress. It fires **once**, at download completion (not
incrementally): `bytesDownloaded` equals `totalBytes` on success, or 0 when the
server did not send `Content-Length`. Do not expect a counting-up live percentage.

```swift
try await RecklessNetworkLoader().ensure(in: dir) { p in
    if let f = p.fractionCompleted {
        print("net: \(Int(f * 100))%")
    } else {
        print("net: \(p.bytesDownloaded) bytes downloaded")
    }
}
```

## Errors

```swift
public enum RecklessNetworkLoader.LoaderError: Error, Sendable {
    case checksumMismatch(String)   // complete downloaded digest did not match expected
    case downloadFailed(String)     // URLSession error
    case fileSystem(String)         // directory creation or atomic move failed
}
```

## The net is never committed

The NNUE network is **gitignored** across all Fianchetto repositories — `*.nnue`
and `networks/` appear in `.gitignore`. This mirrors the policy for Stockfish nets in
SwiftStockfish. The `rust/networks/` directory (used as the staging path for
`cargo test`) is also gitignored.

## Upgrading the network

When Reckless upgrades its evaluation network, update the single constant in
`RecklessNetworkLoader.swift`:

```swift
public static let network = Network(
    filename: "<new-filename>.nnue",
    sha256: "<new-full-sha256>",
    downloadURL: URL(string: "…")!
)
```

No Rust rebuild is needed — the net is never baked into the compiled crate. The fork
removed upstream's `include_bytes!` embed specifically to enable this workflow.

## SHA-256 verification and cross-platform crypto

| Platform | Verification |
|---|---|
| Apple (macOS · iOS · tvOS · watchOS · visionOS) | **Full SHA-256** via `CryptoKit.SHA256` — the complete 64-hex-char digest is compared against `Network.sha256`. |
| Linux · Android | **Full SHA-256** via swift-crypto's source-compatible `Crypto.SHA256`. |

The Apple dependency graph is unchanged when building the normal binary arm —
`CryptoKit` is a system framework, so swift-crypto is resolved only by the
non-Apple/source arm.

## See also

- [Engine API](engine-api.md) — `RecklessEngine.init(networkDirectory:)`.
- [Getting Started](../getting-started.md) — the full lifecycle in context.
