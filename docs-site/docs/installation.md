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

!!! note "Intel CPU requirement"
    The prebuilt Apple x86_64 slices intentionally retain AVX2/BMI2 performance
    and require a Haswell-class Intel CPU or newer. Reckless does not runtime-
    dispatch this binary to a baseline implementation on older Intel hardware.

!!! warning "AGPL-3.0"
    SwiftReckless links the Reckless engine and is a **AGPL-3.0** work. Consuming it
    carries AGPL-3.0 obligations on your application. See
    [AGPL-3.0 licensing](concepts/agpl-licensing.md).

## Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/fianchettochess/SwiftReckless", from: "0.9.8"),
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
`https://github.com/fianchettochess/SwiftReckless`, and add the **SwiftReckless**
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
The xcframework is **committed** to `main` (a path-based binary target), so a fresh
clone links with a plain `swift build` on Apple — no rebuild needed. Rebuild it only
when the Rust engine changes:

```bash
# macOS only (development)
bash Tools/build-macos.sh
swift build
```

For the full Apple gamut (iOS, Mac Catalyst, tvOS, watchOS, visionOS):

```bash
bash Tools/build-xcframework.sh
```

The Rust toolchain prerequisites are documented in [Build model](concepts/build-model.md).
The manual Release workflow builds and tests the exact xcframework, stages it in
a draft release, verifies the uploaded bytes, and creates the final tag once at a
`url:` + `checksum:` manifest. Consuming a tagged version via SPM therefore needs
no local Rust build.

## Verifying the install

```bash
swift build
swift run reckless-smoke    # drives uci → uciok → go depth 1 → bestmove
swift test                  # 4 suites: loader offline + output-cancellation + hermetic download/cancellation, plus the net-guarded live engine smoke
```

The default `swift test` run never touches the network. The live engine smoke test
is gated on the net being staged on disk at `rust/networks/`: present → it runs,
absent → a RECORDED skip (visible in the test log, never a silent pass). It also
skips on the forced-source macOS arm (`SWIFTRECKLESS_FORCE_SOURCE_BUILD=1`), which
links no-op host stubs rather than the real engine. There is no
`SWIFTRECKLESS_INTEGRATION` env var or separate integration target — gating is by
net presence at `rust/networks/` plus not being a forced-source stub build.
