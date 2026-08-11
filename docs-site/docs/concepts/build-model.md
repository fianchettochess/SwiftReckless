# Build model

`Package.swift` selects between two build arms depending on the host environment.
Understanding this is essential for Android / Skip (SkipFuse) integration and for
CI builds that need to produce fresh XCFrameworks.

## The two arms

| Condition | Arm | What links |
|---|---|---|
| Apple host, default (and always under Xcode) | **binary** | `.binaryTarget` → `Frameworks/RecklessFFI.xcframework` + `RecklessBridge.c` |
| Non-Apple host, or `SWIFTRECKLESS_FORCE_SOURCE_BUILD=1` in an Apple command-line build | **source** | `RecklessBridge.c`, plus `RecklessHostStubs.c` on any platform not told an archive is coming. Android links a cross-built `libcreckless.a`; Linux and Windows link `libcreckless.a` / `creckless.lib` under `SWIFTRECKLESS_LINK_ARCHIVE=1` |

### Environment variables

| Variable | Effect |
|---|---|
| `SWIFTRECKLESS_FORCE_SOURCE_BUILD=1` | Selects the source arm outside Xcode. Required for Android / Skip cross-builds; Xcode deliberately ignores it. |
| `RECKLESS_LIB_DIR` | Integration input read by the consuming root package, on every platform. It points to the directory containing the built archive; SwiftReckless does not embed this local path in its published manifest, because a path could only become a link input through `.unsafeFlags`, which would make the package's products unusable to remote consumers. |
| `SWIFTRECKLESS_LINK_ARCHIVE=1` | Desktop (Linux/Windows) opt-in, read by *this* manifest. A boolean, not a path: it declares that a real `creckless` archive is on the linker search path, so the package stops compiling stubs for those platforms and asks for the archive via `.linkedLibrary` — a safe build setting that stays legal in a tagged dependency. All of its effects are scoped `.when(platforms: [.linux, .windows])`. |
| `SWIFTRECKLESS_EXPECT_BACKEND=real\|stub` | Test-suite assertion. Fails the run if the build linked the other backend; records a skip when unset. Set it in any CI job that has an opinion about what it just built. |
| `SWIFTRECKLESS_REQUIRE_NET=1` | Test-suite assertion for the Rust crate. `rust/tests/ffi_smoke.rs` skips when the NNUE net is not staged at `rust/networks/` — right for a developer who has not downloaded 60 MB, wrong for a job whose name promises FFI coverage. Set it wherever the net is staged and a missing net becomes a failure instead of a pass that never touched the FFI. An empty value counts as unset. |

### Which backend did this build get?

The source arm's stub configuration is legitimate — it keeps the Skip/Gradle
host-introspection link working, and it lets a desktop consumer with no archive
still build — but it must never be silent. One preprocessor condition in
`Sources/CReckless/RecklessBackend.h` decides whether the stubs are compiled, and
the same condition is what `rk_backend_is_stub()` (C) and `RecklessBackend.current`
(Swift) report, so the two cannot disagree. `RecklessEngine.init?` names the stub
backend in its failure log, and `reckless-smoke` prints it and exits non-zero
instead of reporting a generic engine failure.

Opting in on desktop and then supplying no archive is a link error, never a quiet
fallback to stubs.

### Xcode lock-in

When `__CFBundleIdentifier == com.apple.dt.Xcode` is detected in the environment,
`Package.swift` forces the binary arm regardless of `SWIFTRECKLESS_FORCE_SOURCE_BUILD`.
This prevents Xcode from attempting to link an Android ELF into a macOS build.

## Building the Apple XCFramework

The XCFramework is **committed** to `main` (a path-based binary target), so a fresh
clone builds on Apple without rebuilding it; rebuild only when the Rust changes. The
release CI publishes it as a GitHub release asset, and a tagged SwiftPM dependency fetches
it automatically via the `url:` + `checksum:` binary target.

### macOS only (development)

```bash
bash Tools/build-macos.sh
# → Frameworks/RecklessFFI.xcframework  (macOS fat slice)
swift build   # binary arm links the freshly built XCFramework
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
flags directly activate Reckless's vectorized NNUE accumulator path:

| Arch | Flags | Rationale |
|---|---|---|
| `aarch64-apple-*` | `+neon` | Always present on ARMv8-A; activates vectorized NNUE |
| `x86_64-apple-*` | `+avx2,+bmi2,+popcnt` | Optimized build; requires Haswell-class hardware or newer |
| `arm64_32-apple-watchos` | `+neon` | Physical Apple Watch architecture used before watchOS 26 |
| `armv7-linux-androideabi` | `+neon,+vfpv3` | Present on all Android 5.0+ ARMv7 devices |
| `x86_64-linux-android` | `+avx2,+popcnt` | Requires AVX2 hardware |
| `i686-linux-android` | `+sse4.2,+popcnt` | Requires SSE4.2 + POPCNT |

Reckless selects the vectorized or scalar NNUE path at compile time via
`#[cfg(target_feature = "…")]`. The XCFramework carries per-architecture slices with their
SIMD code already baked in, so consuming Swift packages inherit the optimal path per
device without any SwiftPM-level architecture flags.

The x86_64 Apple binary intentionally preserves the AVX2/BMI2 performance
uplift. Reckless has no runtime SIMD dispatch, so older Intel CPUs need a
separate baseline build; the prebuilt product requires Haswell-class hardware
or newer even though the operating-system deployment floor remains macOS 10.15.

## Android / Skip (SkipFuse) build

Android uses the **source arm**. Cross-compile the Rust static library for each
Android ABI, then have the consuming root package link the selected slice.

### Rust toolchain prerequisites

```bash
# Tools/build-android.sh installs pinned Rust 1.96.1 and its Android targets.

# cargo-ndk (cross-compile helper)
cargo install cargo-ndk --version 4.1.2 --locked

# NDK r26+ via Android Studio SDK Manager or brew
export ANDROID_NDK_ROOT=~/Library/Android/sdk/ndk/<version>
```

### Build the Android static libraries

```bash
bash Tools/build-android.sh
# → android-libs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libcreckless.a
```

### Configure the consuming root package

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

// Attach this to the consuming root application's target:
.target(
    name: "MyApp",
    dependencies: [.product(name: "SwiftReckless", package: "SwiftReckless")],
    linkerSettings: recklessLinkerSettings
)
```

Then select the absolute output directory and force SwiftReckless's source arm
before building that root package:

```bash
export RECKLESS_LIB_DIR=/absolute/path/to/SwiftReckless/rust/target/aarch64-linux-android/release
export SWIFTRECKLESS_FORCE_SOURCE_BUILD=1
```

### Link the static archive

`libcreckless.a` is a link-time input, not a JNI runtime library. The consuming
root package links the single slice named by `RECKLESS_LIB_DIR` into the final
native output. Do not
put the archive in Gradle `jniLibs`; Android loads `.so` files from that directory,
not `.a` archives. If the surrounding Skip/native build produces a shared
library, package that final `.so` instead.

SwiftReckless itself uses only the safe
`.linkedLibrary("c++", .when(platforms: [.android]))` declaration. Keeping the
machine-local archive path in the root package avoids unsafe flags in the
versioned dependency while preserving the required NDK C++ runtime link.

## Linux and Windows (desktop)

Desktop uses the source arm as well, in the same shape as Android: build the Rust
static library, then hand it to the link. The difference is that the desktop
archive is asked for by *name* — `.linkedLibrary("creckless")`, a safe build
setting — and the consumer supplies only the search path, so no machine-local
path has to enter any manifest.

```bash
bash Tools/build-desktop.sh linux    # → rust/target/x86_64-unknown-linux-gnu/release/libcreckless.a
bash Tools/build-desktop.sh windows  # → rust/target/x86_64-pc-windows-msvc/release/creckless.lib
```

A `staticlib` is assembled by rustc's own archiver and needs no system linker, so
both targets cross-build from any host.

```bash
# Linux
export SWIFTRECKLESS_LINK_ARCHIVE=1
export LIBRARY_PATH=$PWD/rust/target/x86_64-unknown-linux-gnu/release
swift build            # or: swift build -Xlinker -L<that directory>
```

```powershell
# Windows
$env:SWIFTRECKLESS_LINK_ARCHIVE = '1'
swift build -Xlinker "/LIBPATH:$PWD\rust\target\x86_64-pc-windows-msvc\release"
```

!!! warning "Windows: use `/LIBPATH:`, not `LIB`"
    Defining `LIB` in an ordinary shell breaks the build: clang stops
    auto-detecting the MSVC and Windows SDK library directories once `LIB` is
    set, and the link then fails on `msvcrt.lib` / `oldnames.lib` /
    `msvcprt.lib`, including while compiling the package manifest. `LIB` is only
    safe to *append* to inside a Visual Studio developer command prompt.

Verify the result instead of assuming it:

```bash
SWIFTRECKLESS_EXPECT_BACKEND=real swift test
swift run reckless-smoke     # prints "backend: real", then uci → bestmove
```

### Native link dependencies

Taken from `rustc --print native-static-libs` for this crate (the build script
prints the current list on every run) and declared by the package under the
opt-in:

| Target | Needs |
|---|---|
| `x86_64-unknown-linux-gnu` | `-lm -ldl -lpthread -lrt -lutil`, plus `libc`/`libgcc_s` which the Swift driver already links. **No C++ runtime.** |
| `x86_64-pc-windows-msvc` | `kernel32 ntdll userenv ws2_32 dbghelp legacy_stdio_definitions`, plus the default `msvcrt`. **No C++ runtime.** |

`-lc++` remains Android-only: it is the NDK's requirement, not Reckless's.

The desktop archives are not committed. A checkout without one links stubs and
reports it.

## `RecklessHostStubs.c`

In the source arm, any platform that has not been told a real archive is coming
compiles this file, which provides no-op `rk_ffi_*` implementations. That covers
the Skip/Gradle host-introspection pass (a macOS host build carrying the Android
environment, which must link without the Android ELF) and a Linux/Windows
consumer that has not opted in — both link cleanly and neither gets an engine.

The guard is a single condition in `Sources/CReckless/RecklessBackend.h`:
stubs are compiled unless `__ANDROID__` or `RECKLESS_LINK_ARCHIVE` says the real
symbols are arriving from an archive. This matters for correctness, not just
tidiness: a stub object file always beats an archive member (an archive is only
searched for symbols still undefined), so compiling stubs alongside a real
archive would silently produce a dead engine.

## The Reckless fork

The Rust dependency is `github.com/fianchettochess/Reckless.git`, pinned to
tag `swiftreckless-v0.9.1` (commit `de35beac9074137e9776af14859bf6f40562553c`)
(`default-features = false`). The fork makes five patches to the
upstream `codedeliveryservice/Reckless` at tag `v0.9.0`:

1. Adds a `[lib]` target (the pinned upstream Reckless version is binary-only
   and defines no library target or FFI).
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
