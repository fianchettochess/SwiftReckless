# SwiftReckless

A Swift Package Manager wrapper around the [Reckless](https://github.com/codedeliveryservice/Reckless) chess engine — a competitive UCI engine written in Rust (AGPL-3.0).

Structured as a sibling to [SwiftStockfish](https://github.com/your-org/SwiftStockfish) and designed so the existing `UCIInfoParser` / `EngineProbe` layer in Fianchetto can be adapted to either engine with minimal changes.

> **Status: scaffold — exploratory groundwork, NOT wired into the app.**
> The Swift API and FFI ABI are real. The Rust engine crate is not yet vendored.
> See "What's stubbed" below.

---

## Architecture

```
SwiftReckless/
├── Package.swift                   # SPM manifest (CReckless + SwiftReckless + tests)
├── Sources/
│   ├── CReckless/
│   │   ├── include/
│   │   │   └── RecklessBridge.h   # Public C header (imported by Swift as CReckless module)
│   │   └── RecklessBridge.c       # Thin shim: rk_* → rk_ffi_* (Rust symbols)
│   └── SwiftReckless/
│       ├── RecklessEngine.swift    # Public Swift API — mirrors StockfishEngine
│       └── RecklessNetworkLoader.swift  # Downloads v60-7f587dfb.nnue at runtime
├── Tests/
│   └── SwiftRecklessTests/
│       └── SwiftRecklessTests.swift   # Suite 1 (offline) + Suite 3 (integration, gated)
├── rust/                           # Rust FFI crate (creckless)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       └── ffi.rs                  # extern "C" rk_ffi_* symbols
├── Frameworks/                     # xcframework lives here (built by Tools/, not committed yet)
└── Tools/
    ├── build-macos.sh              # macOS fat lib → xcframework
    ├── build-xcframework.sh        # All Apple slices (iOS device + sim + macOS)
    └── build-android.sh            # Android via cargo-ndk
```

### Three-layer design (same as SwiftStockfish)

| Layer | Target | Role |
|---|---|---|
| Rust crate | `creckless` (staticlib) | Runs Reckless UCI loop on a background thread; exposes 4 `extern "C"` symbols |
| C shim | `CReckless` | Imports the staticlib; thin `rk_*` → `rk_ffi_*` forwarder; public C header is the Swift module |
| Swift | `SwiftReckless` | `RecklessEngine` + `RecklessNetworkLoader`; AsyncStream output; mirrors `StockfishEngine` |

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

`rk_create` spawns a background thread running Reckless's UCI `message_loop`.
Input is delivered via an `mpsc::Sender`; output fires the C callback per-line.
`rk_destroy` sends "quit", drops the channel, and `join()`s the thread — after
which no further callbacks can fire. This matches the threading contract in
`StockfishBridge.cpp` exactly.

---

## What's done vs stubbed

| Item | Status |
|---|---|
| Package.swift (binary + source arms) | Done |
| C header (`RecklessBridge.h`) | Done |
| C shim (`RecklessBridge.c`) | Done |
| Rust crate compiles (`cargo build --release`) | **Done — builds clean** |
| Rust FFI ABI (`ffi.rs`) | Done (real ABI, stub bodies) |
| `RecklessEngine.swift` | Done |
| `RecklessNetworkLoader.swift` | Done |
| Test suite (Suite 1 offline + Suite 3 integration) | Done |
| Reckless engine crate vendored in `rust/Cargo.toml` | **TODO** |
| Rust output → C callback wiring (real, not stub) | TODO (depends on engine) |
| xcframework built + committed to `Frameworks/` | TODO (depends on engine) |
| `swift build` succeeds end-to-end | TODO (xcframework not yet present) |

---

## Reckless engine facts

| Property | Value |
|---|---|
| Repo | https://github.com/codedeliveryservice/Reckless |
| Language | Rust (edition 2024) |
| License | **AGPL-3.0** |
| Protocol | UCI (yes — `uci.rs` implements the full message loop) |
| `crate-type` | `["cdylib", "rlib"]` — FFI was already planned upstream |
| NNUE | `v60-7f587dfb.nnue`, fetched at build time by `build/build.rs` from `RecklessNetworks` releases; **NOT embedded in the binary by default** |
| Weight provisioning | Downloaded to `networks/` at cargo-build time; runtime path configurable via `EVALFILE` env var or the `network_path` arg to `rk_ffi_create` |
| Strength | ~3000 Elo (Super-GM level) |
| Dependencies | `libc`, optional `bindgen`/`cc` (for Syzygy via Fathom), optional WASM bindings |

**AGPL-3.0 compatibility note:** AGPL-3.0 is compatible with the GPLv3 Stockfish already shipped in Fianchetto. The combined binary (if ever shipped) must offer source for both engines. Consult legal if distributing over a network service (AGPL §13).

---

## Cross-compile plan

### macOS (development)

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
bash Tools/build-macos.sh   # produces Frameworks/RecklessFFI.xcframework
swift build
```

### iOS (device + Simulator)

```bash
rustup target add \
  aarch64-apple-ios \
  aarch64-apple-ios-sim \
  x86_64-apple-ios
bash Tools/build-xcframework.sh
# → Frameworks/RecklessFFI.xcframework  (3 slices: ios-arm64, ios-sim, macos)
```

**Per-arch SIMD flags** (baked into the build scripts):

| Arch | Flags | Rationale |
|---|---|---|
| `aarch64-*` | `+neon` | Always present on ARMv8-A; activates Reckless's vectorised NNUE accumulator |
| `x86_64-apple-*` | `+avx2,+bmi2,+popcnt` | Present on all Intel Macs (Haswell 2013+) and Rosetta simulator |
| `armv7-linux-androideabi` | `+neon,+vfpv3` | Present on all Android 5.0+ ARMv7 devices |
| `x86_64-linux-android` | `+avx2,+popcnt` | Safe for x86_64 Android emulators |
| `i686-linux-android` | `+sse4.2,+popcnt` | Conservative 32-bit x86 baseline |

Reckless selects the vectorised vs scalar path at compile time via
`#[cfg(target_feature = "avx2")]` / `#[cfg(target_feature = "neon")]` in
`src/nnue/forward/`, so these flags directly activate the fast path.

The xcframework binary target in `Package.swift` carries per-arch slices with
their SIMD code already baked in — the consuming Swift package inherits the
optimal path for each device with no per-architecture compile flags needed at
the SPM level (same design as the Stockfish xcframework in SwiftStockfish).

### Android / Skip (SkipFuse)

```bash
# Prerequisites
rustup target add \
  aarch64-linux-android \
  armv7-linux-androideabi \
  x86_64-linux-android \
  i686-linux-android
cargo install cargo-ndk
# NDK r26+ must be installed; set ANDROID_NDK_ROOT.

bash Tools/build-android.sh
# → android-libs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libcreckless.a
```

Wire into the Fianchetto Android Gradle build:

```groovy
// In app/build.gradle (or the equivalent Skip module):
android {
    sourceSets.main.jniLibs.srcDirs += ['<path-to-SwiftReckless>/android-libs']
}
```

The Skip/SkipFuse bridge pattern (`/* SKIP @bridge */` + SwiftJNI `callStatic`)
documented in the Fianchetto memory files applies unchanged — the Swift API
(`RecklessEngine.send(_:)` / `engine.output`) is identical to `StockfishEngine`.

---

## NNUE weight provisioning

The network (`v60-7f587dfb.nnue`) is **NEVER committed** to this repo or to any
Fianchetto repo. Policy mirrors the `.nnue` ban in the Fianchetto memory files.

Runtime strategy (same as Stockfish nets in SwiftStockfish):
- `RecklessNetworkLoader.ensure(in:)` downloads from the
  [RecklessNetworks](https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/)
  GitHub release page on first launch.
- The SHA-prefix encoded in the filename (`7f587dfb`) is verified after download.
- On Android the same loader runs (Foundation + URLSession via swift-corelibs-foundation).
- When Reckless upgrades its net, update `RecklessNetworkLoader.network` (filename
  + shaPrefix + downloadURL) AND rebuild the Rust crate with the new `NETWORK_NAME`
  in `build/build.rs`.

---

## Toolchain prerequisites (full list)

```bash
# Rust
brew install rust          # or: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
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

## Next concrete steps to a working engine on macOS

1. **Vendor the Reckless engine crate.**
   In `rust/Cargo.toml`, uncomment:
   ```toml
   [dependencies]
   reckless = { git = "https://github.com/codedeliveryservice/Reckless.git", tag = "v0.9.0" }
   ```
   Then `cd rust && cargo build --release`.

2. **Download the NNUE net.**
   Reckless's `build.rs` does this automatically via `curl` if `networks/v60-7f587dfb.nnue`
   is absent. After step 1 it will download ~30 MB on first `cargo build`.

3. **Wire the engine output to the C callback.**
   In `rust/src/ffi.rs`, replace the stub `rk_ffi_create` body (template is inline
   in the file). The key challenge: Reckless's `run()` writes to stdout; redirect
   stdout in the engine thread (pipe pair or a custom `Write` impl) to call
   `deliver_line()` per line.

4. **Build the xcframework.**
   ```bash
   bash Tools/build-xcframework.sh
   ```

5. **Run the offline Swift tests.**
   ```bash
   swift test
   ```
   Suite 1 (offline) should pass; Suite 2 ("Engine returns nil") should now
   FAIL (because the engine is no longer stubbed) — update that test to expect
   a live engine.

6. **Run the integration tests.**
   ```bash
   SWIFTRECKLESS_INTEGRATION=1 swift test --filter RecklessIntegrationTests
   ```
