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
//                       `RecklessHostStubs.c` provides no-op symbols on
//                       non-Android hosts. On Android, the root application
//                       supplies the cross-built Rust archive as a link input.
//
//   SwiftReckless      — Swift-facing API: `RecklessEngine` (mirrors
//                       `StockfishEngine`), `RecklessNetworkLoader` (fetches
//                       the NNUE net at runtime, never committed to the repo).
//
//   SwiftRecklessTests — offline loader unit tests + a net-guarded live engine smoke.
//
// BUILD STATUS (wired & working — see README "Status" section):
//   * The Rust crate at `rust/` depends on the maintained Reckless fork
//     (github.com/fianchettochess/Reckless, pinned tag) and drives it in-process;
//     ffi.rs has real bodies. The NNUE net is loaded at runtime (never baked).
//   * Apple (binary arm): run `Tools/build-macos.sh` (or build-xcframework.sh)
//     once to produce `Frameworks/RecklessFFI.xcframework`, then `swift build`.
//   * Android: source arm via `cargo-ndk` + RECKLESS_LIB_DIR (see README).
//
// The `binaryTarget` points to `Frameworks/RecklessFFI.xcframework`, which IS
// committed (~148 MB, 10 slices, plain git — matches SwiftStockfish) so a fresh
// clone / CI resolves without a Rust rebuild. Rebuild with
// Tools/build-xcframework.sh after a Reckless engine update and commit it.
// The optimized x86_64 slices require AVX2/BMI2/POPCNT (Haswell-class Intel or
// newer); Reckless selects SIMD at compile time and does not runtime-dispatch.

import PackageDescription

// ── Platform detection ────────────────────────────────────────────────────────
// Same dual-arm logic as SwiftStockfish: Apple hosts use the prebuilt
// XCFramework; non-Apple hosts use the source target. Non-Android hosts link
// stubs; an Android root application supplies the Rust archive.
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
let hostIsApple = true
#else
let hostIsApple = false
#endif

// Outside Xcode, set SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 to skip the XCFramework
// and select the source target. Two intended callers:
//   * the Android (Skip/SkipFuse) cross-build, whose root application supplies
//     an aarch64-linux-android `libcreckless.a` link input;
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
// not. So when we detect we're under Xcode we always use the XCFramework; the
// source arm stays reachable only from a real cross-build / CLI `swift build`.
let underXcode = Context.environment["__CFBundleIdentifier"] == "com.apple.dt.Xcode"

let useBinaryEngine = hostIsApple && (underXcode || !forceSource)

// SHA-256 backend for NNUE verification. Apple builds use CryptoKit from the
// OS. Linux/Android builds need swift-crypto's source-compatible `Crypto`
// module; keep it out of the normal Apple dependency graph just as
// SwiftStockfish does.
let cryptoPackageDependencies: [Package.Dependency]
let cryptoTargetDependencies: [Target.Dependency]
if useBinaryEngine {
    cryptoPackageDependencies = []
    cryptoTargetDependencies = []
} else {
    cryptoPackageDependencies = [
        .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
    ]
    cryptoTargetDependencies = [
        .product(name: "Crypto", package: "swift-crypto"),
    ]
}

// ── Engine targets ────────────────────────────────────────────────────────────
let engineTargets: [Target]
if useBinaryEngine {
    // APPLE PATH: link the prebuilt XCFramework and compile the thin C bridge.
    // At release time the Release workflow rewrites this `path:` binaryTarget
    // to `url:` + `checksum:` on the tagged commit (same pattern as
    // SwiftStockfish); `main` stays path-based.
    engineTargets = [
        .binaryTarget(
            name: "RecklessFFI",
            // COMMITTED to main (10 slices, ~150 MB, plain git — see the header
            // note); rebuilt on-demand by Tools/build-xcframework.sh only when
            // the Rust engine changes. The XCFramework carries the full Apple
            // gamut (10 slices): iOS, iOS-sim, macOS, Mac Catalyst, tvOS
            // (+sim), watchOS (+sim), visionOS (+sim). tvOS/watchOS/visionOS
            // are Rust Tier-3, built with a nightly toolchain + `-Z build-std`.
            path: "Frameworks/RecklessFFI.xcframework"
        ),
        .target(
            name: "CReckless",
            dependencies: ["RecklessFFI"],
            path: "Sources/CReckless",
            // Only compile the thin C bridge; the engine lives in the XCFramework.
            sources: ["RecklessBridge.c"],
            publicHeadersPath: "include",
            cSettings: [
                // The bridge includes "RecklessBridge.h" via the public header.
                .headerSearchPath("."),
            ]
        ),
    ]
} else {
    // NON-APPLE / forced-source path. Non-Android hosts compile link-compatible
    // stubs. The Android root application must pass its cross-built
    // libcreckless.a as a positional link input; keeping that local path out of
    // this versioned package preserves remote-consumer safety.
    //
    // Typical invocation (Android cross-build):
    //   SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 \
    //   RECKLESS_LIB_DIR=/path/to/rust/target/aarch64-linux-android/release \
    //   swift build --swift-sdk aarch64-android
    // RECKLESS_LIB_DIR is interpreted by the root application manifest, not
    // by this dependency manifest.

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
                // The Android Rust archive uses the NDK C++ runtime. The root
                // application provides the archive path; this safe declaration
                // propagates -lc++ without poisoning versioned consumers.
                .linkedLibrary("c++", .when(platforms: [.android])),
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
    dependencies: cryptoPackageDependencies,
    targets: engineTargets + [
        .target(
            name: "SwiftReckless",
            dependencies: ["CReckless"] + cryptoTargetDependencies,
            path: "Sources/SwiftReckless"
        ),
        // End-to-end smoke: drives uci → uciok and optionally go depth 1 →
        // bestmove. A convenience CLI entry point that exercises the live engine
        // outside the test harness; I/O is per-instance (no stdout/fd redirect),
        // so its output won't collide with the test capture harness or other
        // subsystems. (Only one live engine per process — see RecklessEngine.)
        //
        // Usage (Apple binary arm, after staging rust/networks/*.nnue):
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
