# Installation

SwiftReckless is a Swift Package Manager library.

## Requirements

| Platform | Minimum |
|---|---|
| macOS | 10.15 |
| iOS | 13 |
| tvOS | 13 |
| watchOS | 6 |
| visionOS | 1 |
| Mac Catalyst | 13 |
| Android | API 21 (Android 5.0 · arm64 · armv7 · x86_64 · x86, source build) |

Swift tools version 6.0. See [Build model](concepts/build-model.md) for the full
platform matrix and cross-compile details.

!!! warning "AGPL-3.0"
    SwiftReckless links the Reckless engine and is a **AGPL-3.0** work. Consuming it
    carries AGPL-3.0 obligations on your application. See
    [AGPL-3.0 licensing](concepts/agpl-licensing.md).

## Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/jaredbrewer/SwiftReckless", from: "0.9.0"),
],
targets: [
    .target(
        name: "MyChessApp",
        dependencies: [
            .product(name: "SwiftReckless", package: "SwiftReckless"),
        ]
    ),
]
```

### Xcode

In Xcode: **File ▸ Add Package Dependencies…**, enter
`https://github.com/jaredbrewer/SwiftReckless`, and add the **SwiftReckless**
library product to your target.

### Products

| Product | Description |
|---|---|
| `SwiftReckless` | High-level Swift API — `RecklessEngine` + `RecklessNetworkLoader`. Recommended for all consumers. |
| `CReckless` | Raw C module exposing the four `rk_*` symbols, for custom engine lifecycle management. |

## Runtime requirement: the NNUE net

!!! danger "The network file is not bundled"
    The NNUE network (`v54-5478683c.nnue`, ~60 MB) is **never committed** to this
    repository or to any Fianchetto repository (`*.nnue` is gitignored). You must
    provision it at runtime via `RecklessNetworkLoader` before the engine can start.
    See [NNUE Network Loader](concepts/nnue-loader.md).

## Apple xcframework

On Apple platforms the engine links a prebuilt `Frameworks/RecklessFFI.xcframework`.
The xcframework is also **gitignored** (never committed, ~90 MB). A fresh clone must
build it once before a plain `swift build` will link on Apple:

```bash
# macOS only (development)
rustup target add aarch64-apple-darwin x86_64-apple-darwin
bash Tools/build-macos.sh
swift build
```

For the full Apple gamut (iOS, Mac Catalyst, tvOS, watchOS, visionOS):

```bash
bash Tools/build-xcframework.sh
```

The Rust toolchain prerequisites are documented in [Build model](concepts/build-model.md).
Release CI publishes the xcframework as a GitHub release asset; a `url:` + `checksum:`
binary target in release tags means consuming a tagged version via SPM requires no local
build step.

## Verifying the install

```bash
swift build
swift run reckless-smoke    # drives uci → uciok → go depth 1 → bestmove
swift test                  # offline loader suite (net-guarded live engine smoke)
```

The default `swift test` run never touches the network. The live engine smoke test
is gated on the net being staged on disk at `rust/networks/`; present → it runs,
absent → it skips and passes.
