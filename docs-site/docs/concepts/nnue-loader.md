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
same convention Stockfish uses. The loader verifies this prefix after downloading.

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
2. If `v54-5478683c.nnue` is already present and passes SHA-256 prefix verification,
   returns immediately — **no download, no network access**.
3. If missing or invalid: downloads to a temporary location, verifies the full
   SHA-256, and atomically moves the file into place.
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
a download is actually in progress.

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
    case checksumMismatch(String)   // downloaded file SHA-256 prefix did not match filename
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

On Apple platforms the loader uses `CryptoKit.SHA256`. On Linux and Android it
conditionally imports swift-crypto's `Crypto` module (the same `SHA256` API).
The Apple dependency graph is unchanged when building for Apple targets.

A partial verification fallback exists: if neither `CryptoKit` nor the crypto
import is available, the loader trusts the download and performs a weak sanity check
using the SHA prefix embedded in the filename.

## See also

- [Engine API](engine-api.md) — `RecklessEngine.init(networkDirectory:)`.
- [Getting Started](../getting-started.md) — the full lifecycle in context.
