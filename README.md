# SwiftReckless

[![Swift Package Index — Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FSwiftReckless%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/fianchettochess/SwiftReckless)
[![Swift Package Index — Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ffianchettochess%2FSwiftReckless%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/fianchettochess/SwiftReckless)
[![Release](https://img.shields.io/github/v/release/fianchettochess/SwiftReckless?sort=semver&label=release&color=blue)](https://github.com/fianchettochess/SwiftReckless/releases)
[![CI](https://github.com/fianchettochess/SwiftReckless/actions/workflows/ci.yml/badge.svg)](https://github.com/fianchettochess/SwiftReckless/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue.svg)](LICENSE)

A Swift Package Manager wrapper around the [Reckless](https://github.com/codedeliveryservice/Reckless)
chess engine — a competitive UCI engine written in Rust (AGPL-3.0).

Structured as a sibling to [SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish)
and designed so the existing `UCIInfoParser` / `EngineProbe` layer in Fianchetto can
be adapted to either engine with minimal changes.

> **Status: released & consumed.** Tagged releases `0.9.0`–`0.9.8` (latest adds
> restartable engine lifetimes — the host can shed and respawn the engine, freeing
> the ~63 MB net between lifetimes); each release publishes `RecklessFFI.xcframework`
> as a `url:` + `checksum:` asset while `main` stays path-based with the prebuilt
> xcframework **committed**. CI builds + tests both package arms on trusted pushes;
> the manual Release workflow rebuilds the binary, stages the net, and validates
> the real Rust/Swift engine before publishing. Consumed by the Fianchetto app
> (iOS and Android). The `RecklessEngine` API
> works end-to-end (verified: `swift test` runs a live
> `uci → uciok / isready → readyok / go → bestmove` handshake when the net is
> staged). The engine is a pinned git dependency on a maintained fork (see
> [Reckless engine facts](#reckless-engine-facts)); it is **not** vendored in-tree
> by design.

---

## Installation

Add **SwiftReckless** with Swift Package Manager:

```swift
.package(url: "https://github.com/fianchettochess/SwiftReckless.git", from: "0.9.8")
```

The prebuilt Apple x86_64 slices intentionally retain AVX2/BMI2 performance
and require a Haswell-class Intel CPU or newer. Reckless does not runtime-
dispatch this binary to a baseline implementation on older Intel hardware.

---

## Architecture

```
SwiftReckless/
├── Package.swift                     # SPM manifest — dual arm (binary xcframework / source),
│                                     #   CReckless + SwiftReckless + reckless-smoke + tests
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
│   └── SwiftRecklessTests/
│       ├── SwiftRecklessTests.swift    # Offline loader + output-cancellation suites + net-guarded live engine smoke
│       ├── RecklessNetworkLoaderCancellationTests.swift  # hermetic Transport-seam download/cancellation suite
│       └── TransportSpy.swift
├── rust/                              # Rust FFI crate (creckless)
│   ├── Cargo.toml                      # [lib] staticlib+rlib; reckless = maintained-fork git dep
│   ├── examples/
│   │   ├── ffi_smoke.rs                # standalone C-ABI exercise
│   │   ├── spike.rs
│   │   └── terminal_guard.rs           # terminal-position-guard exercise (see the fork-patch note in Cargo.toml)
│   ├── src/
│   │   ├── lib.rs
│   │   └── ffi.rs                      # extern "C" rk_ffi_* — real bodies, drive reckless::run_io
│   └── tests/
│       └── ffi_smoke.rs                # cargo-test C-ABI regression (net-guarded)
├── Frameworks/                        # RecklessFFI.xcframework — COMMITTED (path-based main; rebuild only when the Rust changes)
├── .github/workflows/                 # ci.yml (push/PR), release.yml (tested draft release + one-time tag), upstream-watch.yml (daily notify-only)
├── docs-site/                         # MkDocs documentation site
└── Tools/
    ├── build-macos.sh                 # macOS fat lib → xcframework
    ├── build-xcframework.sh           # Full Apple gamut (iOS/macOS/Mac Catalyst/tvOS/watchOS/visionOS)
    └── build-android.sh               # Android staticlibs via cargo-ndk
```

### Three-layer design (same as SwiftStockfish)

| Layer | Target | Role |
|---|---|---|
| Rust crate | `creckless` (`crate-type = ["staticlib", "rlib"]`) | Runs Reckless's UCI loop on a background thread; exposes 4 `extern "C"` symbols |
| C shim | `CReckless` | `RecklessBridge.c` forwards `rk_*` → `rk_ffi_*`; `RecklessHostStubs.c` supplies no-op `rk_ffi_*` on non-Android hosts (source arm); the public C header is the Swift module |
| Swift | `SwiftReckless` | `RecklessEngine` + `RecklessNetworkLoader`; cancellation-safe `RecklessOutput` plus an `AsyncStream` compatibility adapter |

---

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

---

## Build model

`Package.swift` has two arms and selects between them from the environment:

| Condition | Arm | What links |
|---|---|---|
| Apple host, default (and **always** under Xcode) | **binary** | `.binaryTarget` → `Frameworks/RecklessFFI.xcframework` + `RecklessBridge.c` |
| `SWIFTRECKLESS_FORCE_SOURCE_BUILD=1` (Android / forced CLI) | **source** | `RecklessBridge.c` + `RecklessHostStubs.c`; on Android, links `libcreckless.a` from `RECKLESS_LIB_DIR` |

- **`SWIFTRECKLESS_FORCE_SOURCE_BUILD=1`** forces the source arm.
- **`RECKLESS_LIB_DIR`** points at the directory holding the cross-built
  `libcreckless.a` (defaults to the host `rust/target/release`; set it to
  `rust/target/<triple>/release` for a cross-build).
- **Under Xcode** (`__CFBundleIdentifier == com.apple.dt.Xcode`) the binary arm is
  always used, so an Xcode build never tries to link an Android ELF.
- On any non-Android host in the source arm, `RecklessHostStubs.c` provides no-op
  `rk_ffi_*` symbols so the Skip/Gradle host-introspection pass links cleanly.

The prebuilt `xcframework` is **committed** to `main` (a path-based binary target),
so a fresh clone links with a plain `swift build` on Apple — no rebuild needed.
Rebuild it (see below) only when the Rust engine changes; the manual release
workflow creates a detached tag commit whose binary target uses `url:` +
`checksum:`, so the tag itself stays lean without mutating `main`.

Quick sanity check:

```bash
swift build                 # Apple host: binary arm, links the existing xcframework
swift run reckless-smoke    # drives uci → uciok end-to-end
swift test                  # 4 suites: loader offline + output-cancellation + hermetic download/cancellation + net-guarded live engine smoke
```

---

## Building

### macOS (development)

```bash
bash Tools/build-macos.sh   # produces Frameworks/RecklessFFI.xcframework
swift build                 # binary arm links the freshly built xcframework
```

### All Apple platforms (iOS, macOS, Mac Catalyst, tvOS, watchOS, visionOS)

```bash
bash Tools/build-xcframework.sh
# → Frameworks/RecklessFFI.xcframework  (10 slices — the full Apple gamut)
```

The script installs the pinned stable 1.96.1 targets plus
`nightly-2026-07-21` + `rust-src` for the Rust Tier-3 platforms
(tvOS/watchOS/visionOS), which it builds from source via `-Z build-std`. No
manual `rustup target add` is required. These pins produced the committed
xcframework and are also used by release CI.

**Per-arch SIMD flags** (baked into the build scripts):

| Arch | Flags | Rationale |
|---|---|---|
| `aarch64-*` | `+neon` | Always present on ARMv8-A; activates Reckless's vectorised NNUE accumulator |
| `x86_64-apple-*` | `+avx2,+bmi2,+popcnt` | Optimized Intel build; requires Haswell-class AVX2/BMI2 hardware or newer |
| `arm64_32-apple-watchos` | `+neon` | Physical Apple Watch architecture used before watchOS 26 |
| `armv7-linux-androideabi` | `+neon,+vfpv3` | Present on all Android 5.0+ ARMv7 devices |
| `x86_64-linux-android` | `+avx2,+popcnt` | Optimized emulator/device build; requires AVX2 hardware |
| `i686-linux-android` | `+sse4.2,+popcnt` | Requires SSE4.2 + POPCNT |

Reckless selects the vectorised vs scalar NNUE path at compile time via
`#[cfg(target_feature = "…")]`, so these flags directly activate the fast path. The
xcframework carries per-arch slices with their SIMD code already baked in, so the
consuming Swift package inherits the optimal path per device with no per-arch flags at
the SPM level (same design as the Stockfish xcframework in
[SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish)).

> **Intel CPU requirement:** the prebuilt x86_64 slices intentionally favor
> engine strength and require AVX2, BMI2, and POPCNT (Haswell-class or newer).
> Reckless has no runtime SIMD dispatch. Supporting older Intel hardware would
> require a separate baseline product or upstream multiversion dispatch.

### Android / Skip (SkipFuse)

The Android build uses the **source arm**. Cross-build the staticlib, then point SPM at
it with `RECKLESS_LIB_DIR`:

```bash
# Prerequisites
cargo install cargo-ndk --version 4.1.2 --locked
# NDK r26+ installed; set ANDROID_NDK_ROOT.

bash Tools/build-android.sh
# → android-libs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libcreckless.a

# Build the Swift package against a specific slice:
RECKLESS_LIB_DIR=rust/target/aarch64-linux-android/release \
SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 \
  swift build --swift-sdk aarch64-android
```

`libcreckless.a` is a **static link input**. SwiftPM links the single slice named
by `RECKLESS_LIB_DIR` (the example selects `aarch64-linux-android`) into the final
native output. Do not put these archives in Gradle `jniLibs`: that directory is
for loadable `.so` libraries, and Android cannot load a `.a` at runtime. If the
surrounding Skip/native build emits a `.so`, package that final shared library.

The Android source arm currently supplies the archive path through a conditional
SwiftPM `.unsafeFlags` linker setting. That works for the local/cross-build flow
above, but SwiftPM can reject active unsafe flags when this package is consumed as
a version-pinned remote dependency. Treat remote Android consumption as pending
until the linkage is replaced and covered by an end-to-end remote-consumer test.

The Skip/SkipFuse bridge pattern (`/* SKIP @bridge */` + SwiftJNI `callStatic`)
used by the consuming application applies unchanged. Generic consumers
can use the Stockfish-compatible `send(_:)` / `output` surface, but must retain
one long-lived `output` subscription. Concrete consumers that cancel and restart
reads on the same process-lifetime engine must use `cancellationSafeOutput`;
cancelling one of its waiters does not finish output for later searches.

---

## Reckless engine facts

| Property | Value |
|---|---|
| Upstream repo | https://github.com/codedeliveryservice/Reckless |
| Dependency actually used | Maintained fork **`github.com/fianchettochess/Reckless.git`**, pinned tag `swiftreckless-v0.9.1` (commit `de35beac9074137e9776af14859bf6f40562553c`), `default-features = false` (branch `swiftreckless` on upstream tag `v0.9.0`; five patches: a `[lib]` target, runtime NNUE loading, per-instance I/O, terminal-position guarding, and restart-safe lifecycle cleanup) |
| Language | Rust |
| License | **AGPL-3.0** |
| Protocol | UCI (`run_io` implements the message loop) |
| `crate-type` | Upstream Reckless is a **binary-only** crate — no library target, no FFI planned upstream. The fork adds a `[lib]` (`rlib`). The C-linkable `staticlib` comes from the wrapper crate `creckless` (`["staticlib", "rlib"]`). No `cdylib` anywhere. |
| NNUE | `v54-5478683c.nnue`, loaded at **runtime** from the `network_path` passed to `rk_create` (the fork removed upstream's compile-time `include_bytes!` embed) |
| Weight provisioning | Downloaded by `RecklessNetworkLoader` on first launch to a caller-chosen directory; the runtime path is handed to `rk_create`. Net is never baked into the binary. |
| Strength | ~3000 Elo (Super-GM level) |
| Effective dependencies | With `default-features = false`, transitively just `libc`. `cc`/`bindgen` are optional build-deps behind the disabled `syzygy` feature. |

**Licensing.** SwiftReckless is distributed under the **GNU Affero General Public
License, version 3** (see [`LICENSE`](LICENSE)). Because it links the Reckless
engine's compiled code directly into its output (the `RecklessFFI.xcframework` on
Apple platforms, or the source-built `libcreckless` static library elsewhere), the
whole package is an AGPL-3.0 artifact. AGPL-3.0 is compatible with the GPLv3
Stockfish already shipped in Fianchetto; a combined binary (if ever shipped) must
offer source for both engines. **AGPL §13 (Remote Network Interaction):** if you
run a modified version as part of a network-accessible service, you must offer that
service's users the Corresponding Source of your modified version.

---

## NNUE weight provisioning

The network (`v54-5478683c.nnue`) is **NEVER committed** to this repo or to any
Fianchetto repo (`.gitignore` bans `*.nnue` and `networks/`).

Runtime strategy (same as Stockfish nets in
[SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish)):
- `RecklessNetworkLoader().ensure(in:)` downloads from the
  [RecklessNetworks](https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/)
  release page on first launch (~60 MB).
- The complete pinned SHA-256 digest is verified after download on Apple,
  Linux, and Android (CryptoKit on Apple; swift-crypto elsewhere).
- On Android the same loader runs (Foundation + URLSession via swift-corelibs-foundation).
- The downloaded path is passed to `RecklessEngine(networkDirectory:)` →
  `rk_create(network_path)`, which loads it at runtime. When Reckless upgrades its net,
  update `RecklessNetworkLoader.network` (filename + `sha256` + `downloadURL`) — no Rust
  rebuild is needed, because the net is not baked into the crate.

---

## Toolchain prerequisites (full list)

```bash
# Rust — use rustup (NOT `brew install rust`, which is not rustup-managed and
# cannot install the pinned/cross-compile toolchains below).
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Tools/build-*.sh installs stable 1.96.1 and its required targets.
# The full Apple builder additionally installs nightly-2026-07-21 + rust-src.

# Android build tool
cargo install cargo-ndk --version 4.1.2 --locked

# Android NDK (via Android Studio SDK Manager or brew)
# Set: export ANDROID_NDK_ROOT=~/Library/Android/sdk/ndk/<version>
```

---

## Testing

```bash
swift test                    # Swift suites (see below)
cargo test --manifest-path rust/Cargo.toml --locked
```

`Tests/SwiftRecklessTests` has four [swift-testing](https://github.com/apple/swift-testing) suites:

1. **`RecklessNetworkLoader offline tests`** — always runs. Pinned `v54` net spec,
   full-SHA-256 verification (including a same-prefix/wrong-tail regression), the
   SHA-prefix/filename encoding, nil-init without the net, and the prune sweep
   (orphaned `.part` staging files + stale nets).
2. **`Reckless output cancellation`** — the `RecklessOutput` channel:
   pre-subscription buffering, per-waiter cancellation, iterator reuse, and the
   single-forwarding-consumer `output` regression.
3. **`RecklessNetworkLoader cancellation (hermetic)`** — download, cancellation,
   and staging-file lifecycle via the injected `Transport` seam (no network).
4. **`RecklessEngine smoke`** — a real `uci → uciok / isready → readyok / go → bestmove`
   handshake against the live engine. It is **guarded on the staged net** at
   `rust/networks/`: present → the handshake runs; absent → a RECORDED skip
   (visible in the test log, never a silent pass). It also skips on the
   forced-source macOS arm (`SWIFTRECKLESS_FORCE_SOURCE_BUILD=1`), which links
   no-op host stubs rather than the real engine.
   `rust/tests/ffi_smoke.rs` is the equivalent C-ABI regression under `cargo test`.

There is no `SWIFTRECKLESS_INTEGRATION` env var or separate integration target — gating
is by net presence at `rust/networks/` plus not being a forced-source stub build.

## Releasing

Do not push or re-cut a version tag. In **Actions → Release binary → Run
workflow**, choose the current default branch and enter a new stable `N.N.N` version. The
workflow rejects existing tags/releases, rebuilds and inspects all XCFramework
slices, stages and verifies the NNUE network, and runs both locked Rust tests and
the live Swift engine suite against that artifact's macOS arm64 slice. Trusted
Intel CI separately live-tests the committed AVX2/BMI2 x86_64 slice. The release
job uses `macos-26` with Xcode 26.6, then archives and byte-verifies the asset,
creates the URL-based manifest commit on a detached
HEAD, and uploads/re-downloads the asset through a draft release before
publishing. The final tag is created once; `main` remains path-based.

## License

AGPL-3.0 — see [LICENSE](LICENSE) — matching the upstream
[Reckless](https://github.com/codedeliveryservice/Reckless) engine this
package builds from source. The runtime NNUE network is downloaded directly
from [RecklessNetworks](https://github.com/codedeliveryservice/RecklessNetworks)
and is not redistributed in this repository. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency and network
provenance.
