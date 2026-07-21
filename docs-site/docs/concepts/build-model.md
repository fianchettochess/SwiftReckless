# Build model

`Package.swift` selects between two build arms depending on the host environment.
Understanding this is essential for Android / Skip (SkipFuse) integration and for
CI builds that need to produce fresh xcframeworks.

## The two arms

| Condition | Arm | What links |
|---|---|---|
| Apple host, default (and always under Xcode) | **binary** | `.binaryTarget` → `Frameworks/RecklessFFI.xcframework` + `RecklessBridge.c` |
| `SWIFTRECKLESS_FORCE_SOURCE_BUILD=1` | **source** | `RecklessBridge.c` + `RecklessHostStubs.c`; on Android, links `libcreckless.a` from `RECKLESS_LIB_DIR` |

### Environment variables

| Variable | Effect |
|---|---|
| `SWIFTRECKLESS_FORCE_SOURCE_BUILD=1` | Forces the source arm, even on Apple hosts. Required for Android / Skip cross-builds. |
| `RECKLESS_LIB_DIR` | Path to the directory containing the cross-compiled `libcreckless.a`. Defaults to `rust/target/release` (the host debug/release path). Set to `rust/target/<triple>/release` for a cross-build. |

### Xcode lock-in

When `__CFBundleIdentifier == com.apple.dt.Xcode` is detected in the environment,
`Package.swift` forces the binary arm regardless of `SWIFTRECKLESS_FORCE_SOURCE_BUILD`.
This prevents Xcode from attempting to link an Android ELF into a macOS build.

## Building the Apple xcframework

The xcframework is **committed** to `main` (a path-based binary target), so a fresh
clone builds on Apple without rebuilding it; rebuild only when the Rust changes. The
release CI publishes it as a GitHub release asset, and a tagged SPM dependency fetches
it automatically via the `url:` + `checksum:` binary target.

### macOS only (development)

```bash
bash Tools/build-macos.sh
# → Frameworks/RecklessFFI.xcframework  (macOS fat slice)
swift build   # binary arm links the freshly built xcframework
```

### Full Apple gamut

```bash
bash Tools/build-xcframework.sh
# → Frameworks/RecklessFFI.xcframework  (10 slices: iOS + macOS + Mac Catalyst + tvOS + watchOS + visionOS)
```

The script installs its pinned stable 1.96.1 targets automatically. Tier-3
platforms (tvOS / watchOS / visionOS) use `nightly-2026-07-21` + `rust-src` and
`-Z build-std`. Those exact toolchains produced the committed artifact; no
manual `rustup target add` is required.

## Per-arch SIMD flags

The build scripts bake SIMD flags into the Rust compilation per architecture. These
flags directly activate Reckless's vectorised NNUE accumulator path:

| Arch | Flags | Rationale |
|---|---|---|
| `aarch64-apple-*` | `+neon` | Always present on ARMv8-A; activates vectorised NNUE |
| `x86_64-apple-*` | `+avx2,+bmi2,+popcnt` | Optimized build; requires Haswell-class hardware or newer |
| `arm64_32-apple-watchos` | `+neon` | Physical Apple Watch architecture used before watchOS 26 |
| `armv7-linux-androideabi` | `+neon,+vfpv3` | Present on all Android 5.0+ ARMv7 devices |
| `x86_64-linux-android` | `+avx2,+popcnt` | Requires AVX2 hardware |
| `i686-linux-android` | `+sse4.2,+popcnt` | Requires SSE4.2 + POPCNT |

Reckless selects the vectorised vs. scalar NNUE path at compile time via
`#[cfg(target_feature = "…")]`. The xcframework carries per-arch slices with their
SIMD code already baked in, so consuming Swift packages inherit the optimal path per
device without any SPM-level arch flags.

The x86_64 Apple binary intentionally preserves the AVX2/BMI2 performance
uplift. Reckless has no runtime SIMD dispatch, so older Intel CPUs need a
separate baseline build; the prebuilt product requires Haswell-class hardware
or newer even though the operating-system deployment floor remains macOS 10.15.

## Android / Skip (SkipFuse) build

Android uses the **source arm**. Cross-compile the Rust staticlib for each
Android ABI, then point SPM at the target slice.

### Rust toolchain prerequisites

```bash
# Tools/build-android.sh installs pinned Rust 1.96.1 and its Android targets.

# cargo-ndk (cross-compile helper)
cargo install cargo-ndk --version 4.1.2 --locked

# NDK r26+ via Android Studio SDK Manager or brew
export ANDROID_NDK_ROOT=~/Library/Android/sdk/ndk/<version>
```

### Build the Android staticlibs

```bash
bash Tools/build-android.sh
# → android-libs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libcreckless.a
```

### Build the Swift package for a specific ABI

```bash
RECKLESS_LIB_DIR=rust/target/aarch64-linux-android/release \
SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 \
  swift build --swift-sdk aarch64-android
```

### Link the static archive

`libcreckless.a` is a link-time input, not a JNI runtime library. SwiftPM links
the single slice named by `RECKLESS_LIB_DIR` into the final native output. Do not
put the archive in Gradle `jniLibs`; Android loads `.so` files from that directory,
not `.a` archives. If the surrounding Skip/native build produces a shared
library, package that final `.so` instead.

The source arm currently passes the archive path through a conditional SwiftPM
`.unsafeFlags` linker setting. It supports this local cross-build, but active
unsafe flags can make a version-pinned remote dependency ineligible. Remote
Android consumption remains pending a different linkage mechanism and an
end-to-end remote-consumer test.

## `RecklessHostStubs.c`

In the source arm on non-Android hosts (e.g. a CI Linux host), the real Rust
implementation symbols (`rk_ffi_*`) are not linked. `RecklessHostStubs.c` provides
no-op implementations of those symbols so the Skip/Gradle host-introspection pass
links cleanly without an Android NDK.

## The Reckless fork

The Rust dependency is `github.com/fianchettochess/Reckless.git`, pinned to
tag `swiftreckless-v0.9.1` (commit `de35beac9074137e9776af14859bf6f40562553c`)
(`default-features = false`). The fork makes five patches to the
upstream `codedeliveryservice/Reckless` at tag `v0.9.0`:

1. Adds a `[lib]` target (upstream Reckless is binary-only; it has no library target
   and no FFI planned upstream).
2. Replaces the compile-time `include_bytes!` NNUE embed with runtime loading
   (the path is passed to `rk_ffi_create`), enabling runtime net provisioning and
   net upgrades without a Rust rebuild.
3. Adds per-instance I/O so an engine lifetime does not use a process-wide UCI
   input/output channel. The engine still owns other process-global state, so
   overlapping instances remain prohibited.
4. Guards terminal positions with no legal root move and emits `bestmove (none)`
   instead of aborting.
5. Makes sequential engine lifetimes safe by guarding global initialization,
   joining the worker pool, and allowing the NNUE network to be unloaded.

With `default-features = false`, the effective transitive dependency is just `libc`.

## See also

- [C FFI bridge](c-ffi-bridge.md) — the four `rk_*` symbols and the Rust/C/Swift layering.
- [NNUE Network Loader](nnue-loader.md) — provisioning the net at runtime.
- [Installation](../installation.md) — quick-start build commands.
