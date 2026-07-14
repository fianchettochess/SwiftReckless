# SwiftReckless

A Swift Package Manager wrapper around the [Reckless](https://github.com/codedeliveryservice/Reckless)
chess engine — a competitive UCI engine written in Rust (AGPL-3.0).

Structured as a sibling to [SwiftStockfish](https://github.com/fianchettochess/SwiftStockfish)
and designed so the existing `UCIInfoParser` / `EngineProbe` layer in Fianchetto can
be adapted to either engine with minimal changes.

> **Status: wired & working.** The Rust FFI bridge drives Reckless in-process; the
> `RecklessEngine` Swift API works end-to-end on the host (verified: `swift test`
> runs a live `uci → uciok / isready → readyok / go → bestmove` handshake), and the
> Apple `xcframework` builds on-demand. The engine is consumed as a pinned git
> dependency on a maintained fork (see [Reckless engine facts](#reckless-engine-facts));
> it is **not** vendored in-tree by design.

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
│       └── SwiftRecklessTests.swift    # Offline loader suite + net-guarded live engine smoke
├── rust/                              # Rust FFI crate (creckless)
│   ├── Cargo.toml                      # [lib] staticlib+rlib; reckless = maintained-fork git dep
│   ├── examples/
│   │   ├── ffi_smoke.rs                # standalone C-ABI exercise
│   │   └── spike.rs
│   ├── src/
│   │   ├── lib.rs
│   │   └── ffi.rs                      # extern "C" rk_ffi_* — real bodies, drive reckless::run_io
│   └── tests/
│       └── ffi_smoke.rs                # cargo-test C-ABI regression (net-guarded)
├── Frameworks/                        # RecklessFFI.xcframework — built on-demand, GITIGNORED (never committed)
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
`rk_destroy` sends `quit`, drops the channel, and `join()`s the thread — after which no
further callbacks can fire.

I/O is **per-instance**: each engine owns its own channel and callback, with **no
stdout/fd redirection** (a deliberate change from an earlier stdout-hijack spike).
The Rust FFI enforces **one live engine per process** with a lifecycle gate,
because the engine owns process-global tables / NNUE weights. It currently also
allows only **one successful engine lifetime per process**: pinned fork revision
`c864db1` reruns `lookup::initialize()` on a restart, and its second
`init_cuckoo()` can loop forever against the already-populated global table. The
wrapper therefore rejects overlap and later creates with `NULL` instead of
hanging. Removing this temporary containment requires guarding the fork's
`lookup::initialize()` (and NNUE threat-table initialization) with
`std::sync::Once`, bumping the pinned revision, rebuilding the xcframework, and
then changing the FFI regression to expect a successful second lifetime.

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

The prebuilt `xcframework` is **gitignored and never committed** (~90 MB); a fresh
clone must build it once (see below) before a plain `swift build` on Apple will link.

Quick sanity check:

```bash
swift build                 # Apple host: binary arm, links the existing xcframework
swift run reckless-smoke    # drives uci → uciok end-to-end
swift test                  # offline loader suite + (net-guarded) live engine smoke
```

---

## Building

### macOS (development)

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
bash Tools/build-macos.sh   # produces Frameworks/RecklessFFI.xcframework
swift build                 # binary arm links the freshly built xcframework
```

### All Apple platforms (iOS, macOS, Mac Catalyst, tvOS, watchOS, visionOS)

```bash
bash Tools/build-xcframework.sh
# → Frameworks/RecklessFFI.xcframework  (10 slices — the full Apple gamut)
```

The script installs the rustup targets it needs, plus a nightly toolchain +
`rust-src` for the Rust Tier-3 platforms (tvOS/watchOS/visionOS), which it builds
from source via `-Z build-std`. No manual `rustup target add` is required. This
is the same xcframework the release CI publishes as a `url:` asset.

**Per-arch SIMD flags** (baked into the build scripts):

| Arch | Flags | Rationale |
|---|---|---|
| `aarch64-*` | `+neon` | Always present on ARMv8-A; activates Reckless's vectorised NNUE accumulator |
| `x86_64-apple-*` | `+avx2,+bmi2,+popcnt` | Present on all Intel Macs (Haswell 2013+) and Rosetta simulator |
| `armv7-linux-androideabi` | `+neon,+vfpv3` | Present on all Android 5.0+ ARMv7 devices |
| `x86_64-linux-android` | `+avx2,+popcnt` | Safe for x86_64 Android emulators |
| `i686-linux-android` | `+sse4.2,+popcnt` | Conservative 32-bit x86 baseline |

Reckless selects the vectorised vs scalar NNUE path at compile time via
`#[cfg(target_feature = "…")]`, so these flags directly activate the fast path. The
xcframework carries per-arch slices with their SIMD code already baked in, so the
consuming Swift package inherits the optimal path per device with no per-arch flags at
the SPM level (same design as the Stockfish xcframework in SwiftStockfish).

### Android / Skip (SkipFuse)

The Android build uses the **source arm**. Cross-build the staticlib, then point SPM at
it with `RECKLESS_LIB_DIR`:

```bash
# Prerequisites
rustup target add \
  aarch64-linux-android \
  armv7-linux-androideabi \
  x86_64-linux-android \
  i686-linux-android
cargo install cargo-ndk
# NDK r26+ installed; set ANDROID_NDK_ROOT.

bash Tools/build-android.sh
# → android-libs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libcreckless.a  (for Gradle jniLibs packaging)

# Build the Swift package against a specific slice:
RECKLESS_LIB_DIR=rust/target/aarch64-linux-android/release \
SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 \
  swift build --swift-sdk aarch64-android
```

Note the two distinct consumers of the `.a`:
- **SwiftPM** links the single slice named by `RECKLESS_LIB_DIR` (default the
  host `rust/target/release`) at build time — the Android example above sets it
  to the `aarch64-linux-android` slice.
- **Gradle** packages `android-libs/{abi}/libcreckless.a` into the APK's `jniLibs`
  for on-device loading:

```groovy
// In app/build.gradle (or the equivalent Skip module):
android {
    sourceSets.main.jniLibs.srcDirs += ['<path-to-SwiftReckless>/android-libs']
}
```

The Skip/SkipFuse bridge pattern (`/* SKIP @bridge */` + SwiftJNI `callStatic`)
documented in the Fianchetto memory files applies unchanged. Generic consumers
can use the Stockfish-compatible `send(_:)` / `output` surface, but must retain
one long-lived `output` subscription. Concrete consumers that cancel and restart
reads on the same process-lifetime engine must use `cancellationSafeOutput`;
cancelling one of its waiters does not finish output for later searches.

---

## Reckless engine facts

| Property | Value |
|---|---|
| Upstream repo | https://github.com/codedeliveryservice/Reckless |
| Dependency actually used | Maintained fork **`github.com/jaredbrewer/Reckless.git`**, pinned `rev = "420b3d7"`, `default-features = false` (branch `swiftreckless` on upstream tag `v0.9.0`; four patches: a `[lib]` target, runtime NNUE loading, per-instance I/O, and terminal-position guarding) |
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
Fianchetto repo (`.gitignore` bans `*.nnue` and `networks/`). Policy mirrors the
`.nnue` ban in the Fianchetto memory files.

Runtime strategy (same as Stockfish nets in SwiftStockfish):
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
# cannot `rustup target add` the cross-compile targets below).
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup component add rust-src

# Apple targets
rustup target add \
  aarch64-apple-darwin x86_64-apple-darwin \
  aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

# Android targets
rustup target add \
  aarch64-linux-android armv7-linux-androideabi \
  x86_64-linux-android i686-linux-android

# Android build tool
cargo install cargo-ndk

# Android NDK (via Android Studio SDK Manager or brew)
# Set: export ANDROID_NDK_ROOT=~/Library/Android/sdk/ndk/<version>
```

---

## Testing

```bash
swift test          # Swift suites (see below)
cd rust && cargo test   # Rust C-ABI regression (tests/ffi_smoke.rs)
```

`Tests/SwiftRecklessTests` has two [swift-testing](https://github.com/apple/swift-testing) suites:

1. **`RecklessNetworkLoader offline tests`** — always runs. Asserts the pinned `v54`
   net spec, complete SHA-256 verification (including a same-prefix/wrong-tail
   regression), the SHA-prefix/filename encoding, and that `RecklessEngine(networkDirectory:)`
   returns `nil` when the net is absent.
2. **`RecklessEngine smoke`** — a real `uci → uciok / isready → readyok / go → bestmove`
   handshake against the live engine. It is **guarded on the staged net** at
   `rust/networks/`: present → the handshake runs; absent → the test skips-and-passes.
   `rust/tests/ffi_smoke.rs` is the equivalent C-ABI regression under `cargo test`.

There is no `SWIFTRECKLESS_INTEGRATION` env var or separate integration target — gating
is purely by whether the NNUE net is staged on disk.
