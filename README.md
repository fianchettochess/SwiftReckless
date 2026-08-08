# SwiftReckless

[![Swift Package Index — Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FSwiftReckless%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/fianchettochess/SwiftReckless)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FSwiftReckless%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/fianchettochess/SwiftReckless)
[![Release](https://img.shields.io/github/v/release/fianchettochess/SwiftReckless?sort=semver&label=release&color=blue)](https://github.com/fianchettochess/SwiftReckless/releases)
[![CI](https://github.com/fianchettochess/SwiftReckless/actions/workflows/ci.yml/badge.svg)](https://github.com/fianchettochess/SwiftReckless/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

A Swift package that wraps the
[Reckless](https://github.com/codedeliveryservice/Reckless) chess engine, a UCI
engine written in Rust and licensed under AGPL-3.0.

Its API parallels [SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish),
allowing a shared UCI integration layer to support either engine with minimal
adaptation.

> [!NOTE]
> **Release status.** The `0.9.x` wrapper line packages upstream Reckless `0.9`.
> Wrapper-only releases increment the patch component. Release tags use a
> URL-based `RecklessFFI.xcframework` with a checksum, while `main` keeps the prebuilt
> XCFramework committed as a path-based target. Hosted pull-request CI tests the
> Rust FFI and Linux source arm; trusted macOS CI tests both package arms after a
> push to `main` or an explicit manual dispatch. The manual release workflow
> rebuilds the binary, stages the network, tests the Rust targets, exercises the
> terminal guard, tests both Swift package arms and a versioned remote consumer,
> and runs the live engine suites before publication.
> With the network staged, `swift test` verifies the complete
> `uci → uciok / isready → readyok / go → bestmove` exchange. The Fianchetto app
> consumes the package on iOS and Android. The engine remains a pinned Git
> dependency on a maintained fork rather than vendored source; see
> [Reckless engine facts](#reckless-engine-facts).

## Installation

Add SwiftReckless to your package dependencies:

```swift
.package(url: "https://github.com/fianchettochess/SwiftReckless.git", from: "0.9.10")
```

> [!WARNING]
> **Intel CPU requirement.** The prebuilt Apple x86_64 slices intentionally
> retain AVX2/BMI2 performance and require a Haswell-class Intel CPU or newer.
> Reckless does not dispatch at runtime from this binary to a baseline
> implementation on older Intel hardware.

> [!NOTE]
> **Linux host behavior.** Linux and other non-Android source-arm builds use
> link-compatible host stubs; they validate the package surface but do not
> provide a live Reckless engine. Apple uses the binary engine, while Android
> can link a separately cross-built Rust archive as described below.

## Architecture

```text
SwiftReckless/
├── Package.swift                     # SwiftPM manifest — binary XCFramework or source arm,
│                                     #   with CReckless, SwiftReckless, reckless-smoke, and tests
├── Sources/
│   ├── CReckless/
│   │   ├── include/
│   │   │   └── RecklessBridge.h       # Public C header (the CReckless module map)
│   │   ├── RecklessBridge.c           # Thin shim: rk_* → rk_ffi_* (Rust symbols)
│   │   └── RecklessHostStubs.c        # No-op rk_ffi_* for non-Android hosts (source arm)
│   ├── SwiftReckless/
│   │   ├── RecklessEngine.swift        # Public Swift API — mirrors StockfishEngine
│   │   └── RecklessNetworkLoader.swift # Downloads v54-5478683c.nnue at runtime
│   └── reckless-smoke/
│       └── main.swift                  # End-to-end UCI smoke executable (`swift run reckless-smoke`)
├── Tests/
│   ├── RemoteConsumer/                  # SemVer-tagged remote-dependency CI fixture
│   └── SwiftRecklessTests/
│       ├── SwiftRecklessTests.swift    # Offline loader, output cancellation, and net-guarded live engine smoke
│       ├── RecklessNetworkLoaderCancellationTests.swift  # hermetic Transport-seam download/cancellation suite
│       └── TransportSpy.swift
├── rust/                              # Rust FFI crate (creckless)
│   ├── Cargo.toml                      # [lib] staticlib and rlib; Reckless = maintained-fork Git dependency
│   ├── examples/
│   │   ├── ffi_smoke.rs                # standalone C-ABI exercise
│   │   ├── spike.rs
│   │   └── terminal_guard.rs           # terminal-position-guard exercise (see the fork-patch note in Cargo.toml)
│   ├── src/
│   │   ├── lib.rs
│   │   └── ffi.rs                      # extern "C" rk_ffi_* — real bodies, drive reckless::run_io
│   └── tests/
│       └── ffi_smoke.rs                # cargo-test C-ABI regression (net-guarded)
├── Frameworks/                        # RecklessFFI.xcframework — committed (path-based main; rebuild only when Rust changes)
├── .github/workflows/
│   ├── ci.yml                         # Hosted Rust/Linux CI (push/PR/manual)
│   ├── ci-macos-trusted.yml           # Self-hosted macOS CI (main push/manual only)
│   ├── release.yml                    # Tested draft release and one-time tag
│   └── upstream-watch.yml             # Daily notify-only upstream check
├── docs-site/                         # MkDocs documentation site
└── Tools/
    ├── build-macos.sh                 # macOS fat library → XCFramework
    ├── build-xcframework.sh           # All supported Apple destinations
    └── build-android.sh               # Android static libraries via cargo-ndk
```

### Three-layer design (same as SwiftStockfish)

| Layer | Target | Role |
|---|---|---|
| Rust crate | `creckless` (`crate-type = ["staticlib", "rlib"]`) | Runs Reckless's UCI loop on a background thread; exposes four `extern "C"` symbols |
| C shim | `CReckless` | `RecklessBridge.c` forwards `rk_*` → `rk_ffi_*`; `RecklessHostStubs.c` supplies no-op `rk_ffi_*` on non-Android hosts (source arm); the public C header is the Swift module |
| Swift | `SwiftReckless` | `RecklessEngine` and `RecklessNetworkLoader`; cancellation-safe `RecklessOutput` with an `AsyncStream` compatibility adapter |

## C FFI ABI

Defined in `Sources/CReckless/include/RecklessBridge.h` and implemented in `rust/src/ffi.rs`:

```c
typedef const void *RKEngineRef;
typedef void (*RKOutputCallback)(const char *line, const void *context);

RKEngineRef rk_create(const char *network_path);
void        rk_destroy(RKEngineRef engine);
void        rk_set_output_callback(RKEngineRef engine, RKOutputCallback cb, const void *ctx);
void        rk_send_command(RKEngineRef engine, const char *command);
```

`rk_create` loads the NNUE net from `network_path` (via `reckless::nnue::load_network`)
and spawns a named background thread running `reckless::run_io(initial_cmds, rx, output_sink)`.
Input is delivered over an `mpsc::Sender`; each UCI output line fires the C callback.
When the engine thread exits — a normal `quit` or a contained Rust panic — the
callback fires one final time with a **NULL `line`** (an EOF sentinel): treat it as
end-of-output, not a line, so a consumer awaiting output receives EOF instead of
hanging. The Swift wrapper finishes its output stream on this sentinel.
`rk_destroy` sends `quit`, drops the channel, and `join()`s the thread — after which no
further callbacks can fire.

I/O is **per-instance**: each engine owns its own channel and callback, with **no
stdout/fd redirection** (a deliberate change from an earlier stdout-hijack spike).
The Rust FFI enforces **one live engine per process** with a lifecycle gate,
because the engine owns process-global tables / NNUE weights. Sequential
lifetimes are supported by fork tag `swiftreckless-v0.9.1`: a clean
`rk_destroy` joins the worker pool, unloads the NNUE network, and releases the
lifecycle slot so a later `rk_create` can start a fresh engine. Overlapping
lifetimes are still rejected with `NULL`.

## Build model

`Package.swift` selects between two arms using the build host and environment:

| Condition | Arm | What links |
|---|---|---|
| Apple host, default (and **always** under Xcode) | **binary** | `.binaryTarget` → `Frameworks/RecklessFFI.xcframework` and `RecklessBridge.c` |
| Non-Apple host, or `SWIFTRECKLESS_FORCE_SOURCE_BUILD=1` in an Apple command-line build | **source** | `RecklessBridge.c`, plus `RecklessHostStubs.c` on any platform not told an archive is coming. Android links a cross-built `libcreckless.a`; Linux and Windows link `libcreckless.a` / `creckless.lib` under `SWIFTRECKLESS_LINK_ARCHIVE=1` |

- **`SWIFTRECKLESS_FORCE_SOURCE_BUILD=1`** selects the source arm outside
  Xcode. Xcode deliberately ignores it and always uses the binary arm.
- **`RECKLESS_LIB_DIR`** is an integration input for the consuming root
  package — on every platform, desktop included. It points at the directory
  holding the built archive; SwiftReckless does not embed that machine-local
  path in its published manifest, because a path could only become a link input
  through `.unsafeFlags`, and unsafe flags in a versioned dependency make its
  products unusable to every remote consumer.
- **`SWIFTRECKLESS_LINK_ARCHIVE=1`** is the desktop counterpart, and is
  deliberately a boolean rather than a path: it declares "for this build I am
  supplying a real `creckless` archive on the linker search path". SwiftReckless
  then stops compiling stubs for Linux/Windows and asks for the archive through
  `.linkedLibrary`, which is a *safe* build setting and so stays legal in a
  tagged dependency. Every effect is scoped `.when(platforms: [.linux, .windows])`,
  so the variable leaking into an Apple or Android build environment cannot
  change what those arms link.
- **Under Xcode** (`__CFBundleIdentifier == com.apple.dt.Xcode`) the binary arm is
  always used, so an Xcode build never tries to link an Android ELF.
- Any platform in the source arm that has *not* been told an archive is coming
  compiles `RecklessHostStubs.c`, which provides no-op `rk_ffi_*` symbols — so
  the Skip/Gradle host-introspection pass links cleanly, and a desktop consumer
  who has supplied nothing still builds. That configuration is build-only and
  does not provide a live Reckless engine.

### Knowing which backend you got

The stub configuration is supported; an *undetected* stub configuration is not.
A stub build otherwise looks exactly like a real build whose NNUE network is
missing — both are just `RecklessEngine.init?` returning `nil`. So the build
reports itself:

```swift
import SwiftReckless

RecklessBackend.current            // .real or .stub
RecklessBackend.isEngineAvailable  // false ⇒ a build problem, not a provisioning one
```

```c
#include "RecklessBridge.h"
int stubbed = rk_backend_is_stub();  // compile-time constant, safe before rk_create
```

- `RecklessEngine.init?` logs a line naming the stub backend, before it ever
  looks for the net.
- `swift run reckless-smoke` prints `backend: real|stub` and exits non-zero on a
  stub instead of reporting a generic engine failure.
- CI can assert the link it meant to produce: set
  `SWIFTRECKLESS_EXPECT_BACKEND=real|stub` and the test suite fails if the build
  linked the other one. Unset, that test records a skip.

All of these read one preprocessor condition
(`Sources/CReckless/RecklessBackend.h`), which is also what decides whether the
stubs are compiled at all — so the report cannot drift from the backend it
describes.

Opting in and then supplying nothing is a **link error**
(`unable to find library -lcreckless`, `could not open 'creckless.lib'`), never a
quiet fallback to stubs.

The prebuilt XCFramework is committed to `main` as a path-based binary target,
so a fresh clone links with a plain `swift build` on Apple — no rebuild needed.
Rebuild it (see below) only when the Rust engine changes; the manual release
workflow creates a detached tag commit whose binary target uses `url:` and
`checksum:`, so the tag itself stays lean without mutating `main`.

Quick sanity check:

```bash
swift build                 # Apple host: binary arm, links the existing XCFramework
swift test                  # Offline, cancellation, hermetic download, and net-guarded live suites

# Optional live CLI smoke on the Apple binary arm: stage and verify the net first.
mkdir -p rust/networks
curl -fsSL -o rust/networks/v54-5478683c.nnue \
  https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/v54-5478683c.nnue
printf '%s  %s\n' \
  '5478683cb1bababde29ae8f29468a99846726548fc6a0ed54cac40ab6d38efbf' \
  'rust/networks/v54-5478683c.nnue' | shasum -a 256 -c -
swift run reckless-smoke    # drives uci → uciok → go depth 1 → bestmove
```

## Building

### macOS (development)

```bash
bash Tools/build-macos.sh   # produces Frameworks/RecklessFFI.xcframework
swift build                 # binary arm links the freshly built XCFramework
```

### All Apple platforms (iOS, macOS, Mac Catalyst, tvOS, watchOS, visionOS)

```bash
bash Tools/build-xcframework.sh
# → Frameworks/RecklessFFI.xcframework (10 slices across supported destinations)
```

The script installs the pinned stable 1.96.1 targets and
`nightly-2026-07-21` with `rust-src` for the Rust Tier-3 platforms
(tvOS/watchOS/visionOS), which it builds from source via `-Z build-std`. No
manual `rustup target add` is required. These pins produced the committed
XCFramework and are also used by release CI.

**Per-architecture SIMD flags** (baked into the build scripts):

| Arch | Flags | Rationale |
|---|---|---|
| `aarch64-*` | `+neon` | Always present on ARMv8-A; activates Reckless's vectorized NNUE accumulator |
| `x86_64-apple-*` | `+avx2,+bmi2,+popcnt` | Optimized Intel build; requires Haswell-class AVX2/BMI2 hardware or newer |
| `arm64_32-apple-watchos` | `+neon` | Physical Apple Watch architecture used before watchOS 26 |
| `armv7-linux-androideabi` | `+neon,+vfpv3` | Present on all ARMv7 devices running Android 5.0 or later |
| `x86_64-linux-android` | `+avx2,+popcnt` | Optimized emulator/device build; requires AVX2 hardware |
| `i686-linux-android` | `+sse4.2,+popcnt` | Requires SSE4.2 and POPCNT |

Reckless selects the vectorized or scalar NNUE path at compile time via
`#[cfg(target_feature = "…")]`, so these flags directly activate the fast path. The
XCFramework carries per-architecture slices with their SIMD code already baked in,
so the consuming Swift package inherits the optimal path per device with no
per-architecture flags at the SwiftPM level (the same design as the Stockfish
XCFramework in
[SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish)).

> [!WARNING]
> **Intel CPU requirement.** The prebuilt x86_64 slices intentionally favor
> engine strength and require AVX2, BMI2, and POPCNT (Haswell-class or newer).
> Reckless has no runtime SIMD dispatch. Supporting older Intel hardware would
> require a separate baseline product or upstream multiversion dispatch.

### Android / Skip (SkipFuse)

The Android build uses the **source arm**. Cross-build the Rust static library,
then have the consuming root package pass the selected archive as an
Android-only link input. Local archive paths cannot live in SwiftReckless's
published manifest because unsafe dependency flags make versioned products
unusable.

```bash
# Prerequisites
cargo install cargo-ndk --version 4.1.2 --locked
# NDK r26 or newer installed; set ANDROID_NDK_ROOT.

bash Tools/build-android.sh
# → android-libs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libcreckless.a

# Before building the consuming root package, select one absolute output path:
export RECKLESS_LIB_DIR=/absolute/path/to/SwiftReckless/rust/target/aarch64-linux-android/release
export SWIFTRECKLESS_FORCE_SOURCE_BUILD=1
```

In the consuming root manifest, attach the archive to the application target:

```swift
let recklessLinkerSettings: [LinkerSetting]
if let directory = Context.environment["RECKLESS_LIB_DIR"], !directory.isEmpty {
    recklessLinkerSettings = [
        .unsafeFlags(
            ["\(directory)/libcreckless.a"],
            .when(platforms: [.android])
        ),
    ]
} else {
    recklessLinkerSettings = []
}

// In the root application's target:
.target(
    name: "MyApp",
    dependencies: [.product(name: "SwiftReckless", package: "SwiftReckless")],
    linkerSettings: recklessLinkerSettings
)
```

SwiftReckless safely declares the Android C++ runtime with
`.linkedLibrary("c++")`; the root package supplies only the selected Rust
archive path. Non-Android source-arm builds continue to use host stubs.

`libcreckless.a` is a **static link input**. SwiftPM links the single slice named
by `RECKLESS_LIB_DIR` (the example selects `aarch64-linux-android`) into the final
native output. Do not put these archives in Gradle `jniLibs`: that directory is
for loadable `.so` libraries, and Android cannot load a `.a` at runtime. If the
surrounding Skip/native build emits a `.so`, package that final shared library.

> [!NOTE]
> **Remote-dependency safety.** The versioned SwiftReckless dependency contains
> no unsafe build settings. Linux CI verifies this through a SemVer-tagged
> `.package(url:)` consumer. The application remains responsible for testing
> its Android root-target archive link end to end.

The Skip/SkipFuse bridge pattern (`/* SKIP @bridge */` and SwiftJNI `callStatic`)
used by the consuming application applies unchanged. Generic consumers
can use the Stockfish-compatible `send(_:)` / `output` surface, but must retain
one long-lived `output` subscription. Concrete consumers that cancel and restart
reads on the same process-lifetime engine must use `cancellationSafeOutput`;
canceling one of its waiters does not finish output for later searches.

### Linux and Windows (desktop)

Desktop uses the **source arm** too, and follows the Android shape: build the
Rust static library, then hand it to the link. The difference is that the
desktop archive is asked for by name (`.linkedLibrary("creckless")`, a safe
build setting) and the consumer supplies only the *search path*, so nothing
machine-local has to enter a manifest.

```bash
# 1. Build the archive (cross-builds from any host — a staticlib needs no linker)
bash Tools/build-desktop.sh linux          # → rust/target/x86_64-unknown-linux-gnu/release/libcreckless.a
bash Tools/build-desktop.sh windows        # → rust/target/x86_64-pc-windows-msvc/release/creckless.lib

# 2a. Linux: opt in, and put the directory on the linker search path
export SWIFTRECKLESS_LINK_ARCHIVE=1
export LIBRARY_PATH=$PWD/rust/target/x86_64-unknown-linux-gnu/release
swift build
# equivalently:  swift build -Xlinker -L$PWD/rust/target/x86_64-unknown-linux-gnu/release
```

```powershell
# 2b. Windows (PowerShell)
$env:SWIFTRECKLESS_LINK_ARCHIVE = '1'
swift build -Xlinker "/LIBPATH:$PWD\rust\target\x86_64-pc-windows-msvc\release"
```

> [!WARNING]
> On Windows, prefer `-Xlinker /LIBPATH:`. Setting `LIB` from an ordinary shell
> **breaks the build**: clang stops auto-detecting the MSVC and Windows SDK
> library directories once `LIB` is defined, and the link then fails on
> `msvcrt.lib` / `oldnames.lib` / `msvcprt.lib` — including while compiling the
> package manifest. `LIB` is only safe to *append* to inside a Visual Studio
> developer command prompt, where it already carries those directories.

Then confirm what you actually linked, rather than assuming:

```bash
SWIFTRECKLESS_EXPECT_BACKEND=real swift test    # fails if the build linked stubs
swift run reckless-smoke                        # prints "backend: real", then uci → bestmove
```

**Native link dependencies.** These come straight from
`rustc --print native-static-libs` for the crate (the build script prints the
current list on every run) and are declared by the package under the opt-in:

| Target | Needs |
|---|---|
| `x86_64-unknown-linux-gnu` | `-lm -ldl -lpthread -lrt -lutil` (plus `libc`/`libgcc_s`, already on the Swift driver's link line). **No C++ runtime.** |
| `x86_64-pc-windows-msvc` | `kernel32 ntdll userenv ws2_32 dbghelp legacy_stdio_definitions` (plus the default `msvcrt`). **No C++ runtime.** |

`-lc++` stays Android-only: it is the NDK's runtime requirement, not a
Reckless one.

**CPU requirement.** `Tools/build-desktop.sh` defaults to the same
`+avx2,+bmi2,+popcnt` baseline as the x86_64 Apple slices, so its output
requires Haswell-class hardware or newer — Reckless picks its NNUE path at
compile time and has no runtime dispatch. Override with
`RECKLESS_TARGET_FEATURES` for a lower baseline.

The archive is not committed (it is 14–24 MB per target and is rebuilt only when
the engine changes), so a checkout with no archive links stubs and says so.

## Reckless engine facts

| Property | Value |
|---|---|
| Upstream repository | [codedeliveryservice/Reckless](https://github.com/codedeliveryservice/Reckless) |
| Version mapping | Upstream Reckless `0.9` maps to SwiftReckless `0.9.x`; wrapper-only releases increment the patch component |
| Dependency actually used | Maintained fork **`github.com/fianchettochess/Reckless.git`**, pinned tag `swiftreckless-v0.9.1` (commit `de35beac9074137e9776af14859bf6f40562553c`), `default-features = false` (branch `swiftreckless` on upstream tag `v0.9.0`; five patches: a `[lib]` target, runtime NNUE loading, per-instance I/O, terminal-position guarding, and restart-safe lifecycle cleanup) |
| Language | Rust |
| License | **AGPL-3.0** |
| Protocol | UCI (`run_io` implements the message loop) |
| `crate-type` | The pinned upstream Reckless version is **binary-only** and defines no library target or FFI. The maintained fork adds a `[lib]` (`rlib`). The C-linkable `staticlib` comes from the wrapper crate `creckless` (`["staticlib", "rlib"]`). Neither crate defines a `cdylib`. |
| NNUE | `v54-5478683c.nnue`, loaded at **runtime** from the `network_path` passed to `rk_create` (the fork removed upstream's compile-time `include_bytes!` embed) |
| Weight provisioning | Downloaded by `RecklessNetworkLoader` on first launch to a caller-chosen directory; the runtime path is handed to `rk_create`. The network is never baked into the binary. |
| Effective dependencies | With `default-features = false`, transitively just `libc`. `cc`/`bindgen` are optional build-deps behind the disabled `syzygy` feature. |

**Licensing.** SwiftReckless is distributed under the **GNU Affero General Public
License, version 3** (see [`LICENSE`](LICENSE)). Because it links the Reckless
engine's compiled code directly into its output (the `RecklessFFI.xcframework` on
Apple platforms or the source-built `libcreckless` static library on Android), the
whole package is an AGPL-3.0 artifact. Non-Android source-arm host stubs do not
contain the engine. AGPL-3.0 is compatible with the GPLv3
Stockfish already shipped in Fianchetto; a combined binary (if ever shipped) must
offer source for both engines. **AGPL §13 (Remote Network Interaction):** if you
run a modified version as part of a network-accessible service, you must offer that
service's users the Corresponding Source of your modified version.

## NNUE weight provisioning

The network (`v54-5478683c.nnue`) is not committed to this repository or any
Fianchetto repository (`.gitignore` excludes `*.nnue` and `networks/`).

Runtime strategy (the same as Stockfish networks in
[SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish)):

- `RecklessNetworkLoader().ensure(in:)` downloads from the
  [RecklessNetworks](https://github.com/codedeliveryservice/RecklessNetworks/releases/tag/networks)
  release page on first launch (~60 MB).
- The complete pinned SHA-256 digest is verified after download on Apple,
  Linux, and Android (CryptoKit on Apple; swift-crypto elsewhere).
- On Android, the same loader runs (Foundation and URLSession via swift-corelibs-foundation).
- The downloaded path is passed to `RecklessEngine(networkDirectory:)` →
  `rk_create(network_path)`, which loads it at runtime. When Reckless upgrades its network,
  update `RecklessNetworkLoader.network` (`filename`, `sha256`, and `downloadURL`) — no Rust
  rebuild is needed because the network is not baked into the crate.

## Toolchain prerequisites

```bash
# Rust — use rustup (NOT `brew install rust`, which is not rustup-managed and
# cannot install the pinned/cross-compile toolchains below).
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# The Tools/build-*.sh scripts install stable 1.96.1 and its required targets.
# The full Apple builder additionally installs nightly-2026-07-21 and rust-src.

# Android build tool
cargo install cargo-ndk --version 4.1.2 --locked

# Android NDK (via Android Studio SDK Manager or brew)
# Set: export ANDROID_NDK_ROOT=~/Library/Android/sdk/ndk/<version>
```

## Testing

```bash
swift test
SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 swift test --scratch-path .build-source
cargo test --manifest-path rust/Cargo.toml --locked --all-targets

# With the NNUE network staged:
cargo run --manifest-path rust/Cargo.toml --locked --example terminal_guard
```

`Tests/SwiftRecklessTests` has four [swift-testing](https://github.com/apple/swift-testing) suites:

1. **`RecklessNetworkLoader offline tests`** — always runs. Pinned `v54` net spec,
   full-SHA-256 verification (including a same-prefix/wrong-tail regression), the
   SHA-prefix/filename encoding, nil-init without the net, and the prune sweep
   (orphaned `.part` staging files and stale networks).
2. **`Reckless output cancellation`** — the `RecklessOutput` channel:
   pre-subscription buffering, per-waiter cancellation, iterator reuse, and the
   single-forwarding-consumer `output` regression.
3. **`RecklessNetworkLoader cancellation (hermetic)`** — download, cancellation,
   and staging-file lifecycle via the injected `Transport` seam (no network).
4. **`RecklessEngine smoke`** — a real `uci → uciok / isready → readyok / go → bestmove`
   handshake against the live engine. It is **guarded on the staged net** at
   `rust/networks/`: present → the handshake runs; absent → a recorded skip
   (visible in the test log, never a silent pass). It also skips on the
   forced-source macOS arm (`SWIFTRECKLESS_FORCE_SOURCE_BUILD=1`), which links
   no-op host stubs rather than the real engine. Linux source-arm builds use the
   same host stubs and cannot run the live-engine suite.
   `rust/tests/ffi_smoke.rs` is the equivalent C-ABI regression under `cargo test`.

There is no `SWIFTRECKLESS_INTEGRATION` environment variable or separate
integration target. Apple binary-arm execution is gated by network presence at
`rust/networks/`; non-Android source-arm builds use host stubs and cannot run the
live engine.

Linux CI also creates an ephemeral SemVer-tagged Git repository and builds the
fixture in `Tests/RemoteConsumer` through a versioned `.package(url:)`
dependency. This catches unsafe dependency settings that a root-package or
local-path build would miss. The release workflow repeats that fixture on its
trusted host after rebuilding the artifact.

The pull-request-capable `ci.yml` workflow uses GitHub-hosted runners only. The
separate `ci-macos-trusted.yml` workflow runs the source- and binary-arm macOS
tests on the self-hosted Intel runner only after a push to `main` or a trusted
manual dispatch. Before public visibility, the organization runner group must
restrict each self-hosted workflow to its exact workflow file on
`refs/heads/main`; `runs-on` labels route jobs but are not an authorization
boundary.

## Releasing

Releases are produced by **Actions → Release binary → Run workflow**, not by
pushing a tag. Choose the current default branch and enter a new stable `N.N.N`
version. Existing versions are never re-cut or force-moved. The workflow rejects
versions outside the `.upstream-version`-derived `0.9.x` wrapper line, existing
tags, and existing releases. It rebuilds and inspects all XCFramework slices,
then stages and verifies the NNUE network before running every Rust target,
the terminal-position guard, the source-arm Swift suite, the rebuilt binary-arm
Swift suite, and the SemVer remote-consumer fixture. The source arm deliberately
uses host stubs, so its live-engine test records the expected skip; the binary
arm must run the live handshake against the artifact's macOS x86_64 slice.
The release job runs on the trusted self-hosted Intel Mac Pro, requires the full
`/Applications/Xcode.app` installation with an Xcode 26.x / Apple Swift 6.x
toolchain, and checks x86_64 plus AVX2/BMI2/POPCNT before building. Patch-level
Xcode and Swift updates are accepted when those capabilities remain available.
ARM slices are cross-built and architecture/deployment-validated; Xcode Cloud
will provide arm64 runtime coverage once enabled. The workflow then archives
and byte-verifies the asset, creates the URL-based manifest commit on a detached
HEAD, and uploads/re-downloads the asset through a draft release before
publishing. The final tag is created once; `main` remains path-based.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for Swift and Rust testing, generated
artifact, privacy, and source-provenance requirements. Report security issues
using the private process in [SECURITY.md](SECURITY.md), not a public issue
containing sensitive details.

## License

SwiftReckless uses AGPL-3.0, matching the upstream
[Reckless](https://github.com/codedeliveryservice/Reckless) engine; see
[LICENSE](LICENSE). The runtime NNUE network is downloaded directly from
[RecklessNetworks](https://github.com/codedeliveryservice/RecklessNetworks) and
is not redistributed in this repository. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency and network
provenance.
