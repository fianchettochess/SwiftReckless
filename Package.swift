// swift-tools-version: 6.0
//
// SwiftReckless — a Swift Package Manager wrapper around the Reckless chess
// engine (AGPL-3.0, https://github.com/codedeliveryservice/Reckless).
//
// DEPLOYMENT FLOOR: iOS 13.0 / macOS 10.15, matching SwiftStockfish so the
// two packages can be swapped in/out of the same app target without bumping
// the OS requirement.
//
// ARCHITECTURE — three targets, mirroring SwiftStockfish:
//
//   CReckless         — C interop layer.  On Apple hosts (binary arm) this
//                       compiles the thin C bridge (`RecklessBridge.h` +
//                       `RecklessBridge.c`) and links the pre-built static
//                       library `libcreckless.a` via the `RecklessFFI`
//                       binaryTarget (the Rust FFI crate at `rust/`, built by
//                       Tools/build-xcframework.sh).  In the source arm
//                       (Android / forced source) the same C bridge compiles;
//                       the Rust lib is supplied via RECKLESS_LIB_DIR on
//                       Android, and `RecklessHostStubs.c` provides no-op
//                       symbols on every other host (see `linkerSettings` below).
//
//   SwiftReckless      — Swift-facing API: `RecklessEngine` (mirrors
//                       `StockfishEngine`), `RecklessNetworkLoader` (fetches
//                       the NNUE net at runtime, never committed to the repo).
//
//   SwiftRecklessTests — offline loader unit tests + a net-guarded live engine smoke.
//
// BUILD STATUS (wired & working — see README "Status" section):
//   * The Rust crate at `rust/` depends on the maintained Reckless fork
//     (github.com/jaredbrewer/Reckless, pinned rev) and drives it in-process;
//     ffi.rs has real bodies. The NNUE net is loaded at runtime (never baked).
//   * Apple (binary arm): run `Tools/build-macos.sh` (or build-xcframework.sh)
//     once to produce `Frameworks/RecklessFFI.xcframework`, then `swift build`.
//   * Android: source arm via `cargo-ndk` + RECKLESS_LIB_DIR (see README).
//
// The `binaryTarget` points to `Frameworks/RecklessFFI.xcframework`, which is
// built on-demand and GITIGNORED (never committed, ~90 MB) — a fresh clone must
// build it once. At release time CI rewrites the binaryTarget to url+checksum.

import PackageDescription

// ── Platform detection ────────────────────────────────────────────────────────
// Same dual-arm logic as SwiftStockfish: Apple hosts use the prebuilt
// xcframework; non-Apple hosts must supply the Rust lib separately (or via a
// later source-build arm).
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let hostIsApple = true
#else
let hostIsApple = false
#endif

// Set SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 to skip the xcframework and force the
// caller-supplied-lib path. Two intended callers:
//   * the Android (Skip/SkipFuse) cross-build, which supplies an
//     aarch64-linux-android `libcreckless.a` via RECKLESS_LIB_DIR;
//   * a from-source macOS dev build via CLI `swift build`.
let forceSource = Context.environment["SWIFTRECKLESS_FORCE_SOURCE_BUILD"] == "1"

// HARDENING (learned the hard way — see the "not a mach-o file" incident): if
// SWIFTRECKLESS_FORCE_SOURCE_BUILD ever leaks into the *Xcode GUI* environment
// — e.g. someone runs `launchctl setenv SWIFTRECKLESS_FORCE_SOURCE_BUILD 1` to
// prime an Android build session — then a plain iOS/macOS build in Xcode would
// wrongly take the source arm and try to link the Android ELF `libcreckless.a`,
// failing with "Archive member '/' not a mach-o file". Xcode, and every process
// it spawns (including SwiftPM manifest evaluation), inherits
// __CFBundleIdentifier=com.apple.dt.Xcode; the gradle/Skip Android build does
// not. So when we detect we're under Xcode we ALWAYS use the xcframework — the
// source arm stays reachable only from a real cross-build / CLI `swift build`.
let underXcode = Context.environment["__CFBundleIdentifier"] == "com.apple.dt.Xcode"

let useBinaryEngine = hostIsApple && (underXcode || !forceSource)

// ── Engine targets ────────────────────────────────────────────────────────────
let engineTargets: [Target]
if useBinaryEngine {
    // APPLE PATH: link the prebuilt xcframework + compile the thin C bridge.
    // TODO: replace the `path:` binaryTarget with `url:` + `checksum:` at
    // release time (same pattern as SwiftStockfish).
    engineTargets = [
        .binaryTarget(
            name: "RecklessFFI",
            url: "https://github.com/jaredbrewer/SwiftReckless/releases/download/0.9.1/RecklessFFI.xcframework.zip",
            checksum: "ac90618a3a09206a8bba6a56ad5fcdb250bf369e50daa9579f0d875027314e47"
        ),
        .target(
            name: "CReckless",
            dependencies: ["RecklessFFI"],
            path: "Sources/CReckless",
            // Only compile the thin C bridge; the engine lives in the xcframework.
            sources: ["RecklessBridge.c"],
            publicHeadersPath: "include",
            cSettings: [
                // The bridge includes "RecklessBridge.h" via the public header.
                .headerSearchPath("."),
            ]
        ),
    ]
} else {
    // NON-APPLE / forced-source path: the Rust static lib must be built and
    // placed at the directory referenced by RECKLESS_LIB_DIR, then linked
    // manually via linkerSettings.  This is the path taken by the Android
    // (Skip / SkipFuse) build.
    //
    // Typical invocation (Android cross-build):
    //   RECKLESS_LIB_DIR=/path/to/rust/target/aarch64-linux-android/release \
    //   SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 \
    //   swift build --swift-sdk aarch64-android
    //
    // RECKLESS_LIB_DIR must point to the DIRECTORY that contains libcreckless.a
    // (not the .a itself). The linker flag passes the full path to the archive.
    //
    // Fallback: if RECKLESS_LIB_DIR is unset we fall back to the repo-relative
    // host release path. In practice the Android arm (the only consumer of the
    // libPath below — see the `.android` platform gate) always sets the var
    // explicitly to a per-triple dir, so this default is rarely linked.
    let libDir = Context.environment["RECKLESS_LIB_DIR"]
        ?? "rust/target/release"
    let libPath = libDir + "/libcreckless.a"

    engineTargets = [
        .target(
            name: "CReckless",
            path: "Sources/CReckless",
            // RecklessHostStubs.c provides no-op rk_ffi_* for every NON-Android
            // platform in this arm (guarded by #if !defined(__ANDROID__)), so
            // the Skip/gradle HOST-introspection build (macOS host targeting
            // arm64-apple-ios, same env as the Android cross-build) links
            // WITHOUT the ELF .a. Without this, that host link failed
            // ("archive member '/' not a mach-o file") and skipstone silently
            // reused STALE transpiled Kotlin while gradle reported SUCCESS.
            sources: ["RecklessBridge.c", "RecklessHostStubs.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ],
            linkerSettings: [
                // Link the locally-built Rust static library by passing its
                // absolute path directly to the linker.  Passing the full path
                // (rather than -L/-l) is required for ELF/Android targets where
                // the Swift driver's -Xlinker passthrough can silently drop
                // positional flags when wrapped through clang.
                // Build the .a first:
                //   cargo build --release \
                //     --target aarch64-linux-android \
                //     --manifest-path rust/Cargo.toml
                // Then set RECKLESS_LIB_DIR to the output directory.
                //
                // ANDROID-ONLY: the .a here is an aarch64-linux-android ELF
                // archive — linking it on any Apple pass is what produced the
                // "not a mach-o file" failure. Non-Android builds of this arm
                // resolve rk_ffi_* from RecklessHostStubs.c instead.
                .unsafeFlags([
                    libPath,
                    "-lc++",
                ], .when(platforms: [.android])),
            ]
        ),
    ]
}

// ── Package ───────────────────────────────────────────────────────────────────
let package = Package(
    name: "SwiftReckless",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
        .macCatalyst(.v13),
    ],
    products: [
        // Primary Swift-facing API.
        .library(
            name: "SwiftReckless",
            type: .static,
            targets: ["SwiftReckless"]
        ),
        // Low-level C bridge for consumers that want raw UCI access.
        .library(
            name: "CReckless",
            type: .static,
            targets: ["CReckless"]
        ),
    ],
    targets: engineTargets + [
        .target(
            name: "SwiftReckless",
            dependencies: ["CReckless"],
            path: "Sources/SwiftReckless"
        ),
        // End-to-end smoke: drives uci → uciok and optionally go depth 1 →
        // bestmove. A convenience CLI entry point that exercises the live engine
        // outside the test harness; I/O is per-instance (no stdout/fd redirect),
        // so its output won't collide with the test capture harness or other
        // subsystems. (Only one live engine per process — see RecklessEngine.)
        //
        // Usage (Apple host uses the prebuilt xcframework):
        //   swift run reckless-smoke
        //
        .executableTarget(
            name: "reckless-smoke",
            dependencies: ["SwiftReckless"],
            path: "Sources/reckless-smoke"
        ),
        .testTarget(
            name: "SwiftRecklessTests",
            dependencies: ["SwiftReckless"],
            path: "Tests/SwiftRecklessTests"
        ),
    ]
)
