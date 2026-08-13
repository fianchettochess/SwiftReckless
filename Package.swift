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
//                       (Android / desktop / forced source) the same C bridge
//                       compiles; `RecklessHostStubs.c` provides no-op symbols
//                       for every platform in that arm that has NOT opted into
//                       a real archive (SWIFTRECKLESS_LINK_ARCHIVE=1 +
//                       RECKLESS_LIB_DIR). Android stubs by DEFAULT — an
//                       Android dylib face with no supplied archive otherwise
//                       fails to load ("cannot locate symbol rk_ffi_create",
//                       because Android resolves every symbol at dlopen) — and
//                       Android consumers that DO supply the cross-built Rust
//                       archive opt in the same way as Linux/Windows.
//                       `rk_backend_is_stub()` / `RecklessBackend.current`
//                       report which of the two a build actually got.
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
//   * Linux / Windows desktop: source arm via `Tools/build-desktop.sh` +
//     SWIFTRECKLESS_LINK_ARCHIVE=1 and a linker search path (see README).
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

// ── Desktop (Linux / Windows) real-engine opt-in ──────────────────────────────
// SWIFTRECKLESS_LINK_ARCHIVE=1 declares "for this build I am supplying a real
// creckless archive on the linker search path". It is a BOOLEAN, deliberately
// not a path:
//
//   * A path could only be turned into a link input here with
//     `.unsafeFlags(["-L…"])`, and unsafe flags in a VERSIONED dependency make
//     its products unusable to every remote consumer — the precise property
//     this manifest exists to protect (Tests/RemoteConsumer guards it in CI).
//     A boolean needs only `.linkedLibrary`, which is a safe build setting and
//     is legal in a tagged dependency.
//
//   * So RECKLESS_LIB_DIR keeps its documented meaning on EVERY platform,
//     desktop included: it is an integration input for the ROOT application
//     (or for Tools/build-desktop.sh, which turns it into a linker search
//     path), never read by this dependency manifest. Reading it here would
//     also quietly change the Android build, where it is always set.
//
// Failure behaviour is loud in both directions, which is the whole point:
//   * opted in, no archive found      → the link fails at build time
//                                        ("unable to find library -lcreckless",
//                                        "could not open 'creckless.lib'").
//   * not opted in (default)          → honest stubs, and `rk_backend_is_stub()`
//                                        / `RecklessBackend.current` say so.
// Every effect below is additionally gated `.when(platforms: [.linux, .windows])`,
// so this variable leaking into an Apple or Android build environment — the
// hazard the __CFBundleIdentifier hardening above was written for — cannot
// change what those arms link.
let desktopArchiveOptIn = Context.environment["SWIFTRECKLESS_LINK_ARCHIVE"] == "1"

// SHA-256 backend for NNUE verification. Apple builds use CryptoKit from the
// OS. NON-APPLE hosts (Android/Linux) use the vendored streaming SHA256 in
// Sources/SwiftReckless/SHA256.swift (FIPS 180-4, vector-tested) — no external
// crypto dependency at all. This also avoids SwiftPM 6.3.3's Android
// cross-build pruning of the `Crypto` module name, which dropped swift-crypto
// from the plan ("no such module 'Crypto'").
let cryptoPackageDependencies: [Package.Dependency] = []
let cryptoTargetDependencies: [Target.Dependency] = []

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
    // NON-APPLE / forced-source path. Every platform in this arm that has not
    // been told a real archive is coming compiles link-compatible stubs. The
    // Android root application must pass its cross-built libcreckless.a as a
    // positional link input; keeping that local path out of this versioned
    // package preserves remote-consumer safety.
    //
    // Typical invocation (Android cross-build):
    //   SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 \
    //   RECKLESS_LIB_DIR=/path/to/rust/target/aarch64-linux-android/release \
    //   swift build --swift-sdk aarch64-android
    // RECKLESS_LIB_DIR is interpreted by the root application manifest, not
    // by this dependency manifest.
    //
    // Typical invocation (Linux / Windows desktop, host build):
    //   bash Tools/build-desktop.sh                  # → the archive
    //   SWIFTRECKLESS_LINK_ARCHIVE=1 \
    //   LIBRARY_PATH=/path/to/rust/target/x86_64-unknown-linux-gnu/release \
    //   swift build
    // `swift build -Xlinker -L<dir>` works equally well; the search path is the
    // consumer's to supply, exactly as the archive path is on Android. On
    // Windows use `-Xlinker /LIBPATH:<dir>` and NOT the LIB environment
    // variable: defining LIB outside a Visual Studio developer prompt stops
    // clang auto-detecting the MSVC/Windows SDK library directories and breaks
    // the link (msvcrt.lib / oldnames.lib / msvcprt.lib), manifest compile
    // included.

    var sourceCSettings: [CSetting] = [
        .headerSearchPath("."),
        // Tells Sources/CReckless/RecklessBackend.h that this is the source
        // arm. The binary arm never defines it, so the same header reports a
        // real backend there without knowing anything about XCFrameworks.
        .define("RECKLESS_SOURCE_ARM", to: "1"),
    ]

    var sourceLinkerSettings: [LinkerSetting] = [
        // The Android Rust archive uses the NDK C++ runtime. The root
        // application provides the archive path; this safe declaration
        // propagates -lc++ without poisoning versioned consumers.
        //
        // This stays ANDROID-ONLY on purpose. `rustc --print native-static-libs`
        // for the desktop targets asks for no C++ runtime at all:
        //   x86_64-unknown-linux-gnu → -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
        //   x86_64-pc-windows-msvc   → legacy_stdio_definitions.lib kernel32.lib
        //                              ntdll.lib userenv.lib ws2_32.lib
        //                              dbghelp.lib /defaultlib:msvcrt
        // (measured against the archives this crate actually produces, 2026-08).
        .linkedLibrary("c++", .when(platforms: [.android])),
    ]

    if desktopArchiveOptIn {
        // 1. Stop compiling stubs for the opted-in platforms. This is
        //    the load-bearing half: a stub object file always beats an archive
        //    member, so leaving them in would link a silent no-op engine on top
        //    of a perfectly good archive. Android is included: an Android
        //    consumer that supplies the cross-built libcreckless.a opts in the
        //    same way as desktop (SWIFTRECKLESS_LINK_ARCHIVE=1 + RECKLESS_LIB_DIR).
        sourceCSettings.append(
            .define("RECKLESS_LINK_ARCHIVE", to: "1", .when(platforms: [.linux, .windows, .android]))
        )
        // 2. Ask for the archive by name. `.linkedLibrary` is a SAFE setting, so
        //    this survives in a tagged dependency; the consumer supplies the
        //    search path. If they opted in and supplied nothing, the link fails
        //    here — which is the intended, loud outcome.
        //    `-lcreckless` resolves to `libcreckless.a` (Linux/Android) and
        //    `creckless.lib` (MSVC), the two names cargo already emits.
        sourceLinkerSettings.append(
            .linkedLibrary("creckless", .when(platforms: [.linux, .windows, .android]))
        )
        // 3. The Rust staticlib's own native dependencies, from the
        //    `--print native-static-libs` lists above. libc/libgcc_s come from
        //    the Swift driver's own link line on Linux, and msvcrt is MSVC's
        //    default lib, so neither is repeated here.
        sourceLinkerSettings += [
            .linkedLibrary("m", .when(platforms: [.linux])),
            .linkedLibrary("dl", .when(platforms: [.linux])),
            .linkedLibrary("pthread", .when(platforms: [.linux])),
            .linkedLibrary("rt", .when(platforms: [.linux])),
            .linkedLibrary("util", .when(platforms: [.linux])),
            .linkedLibrary("kernel32", .when(platforms: [.windows])),
            .linkedLibrary("ntdll", .when(platforms: [.windows])),
            .linkedLibrary("userenv", .when(platforms: [.windows])),
            .linkedLibrary("ws2_32", .when(platforms: [.windows])),
            .linkedLibrary("dbghelp", .when(platforms: [.windows])),
            .linkedLibrary("legacy_stdio_definitions", .when(platforms: [.windows])),
        ]
    }

    engineTargets = [
        .target(
            name: "CReckless",
            path: "Sources/CReckless",
            // RecklessHostStubs.c provides no-op rk_ffi_* for every platform in
            // this arm that is NOT linking a real archive (the condition lives
            // in RecklessBackend.h), so the Skip/gradle HOST-introspection build
            // (macOS host targeting arm64-apple-ios, same env as the Android
            // cross-build) links WITHOUT the ELF .a. Without this, that host
            // link failed ("archive member '/' not a mach-o file") and skipstone
            // silently reused STALE transpiled Kotlin while gradle reported
            // SUCCESS. The desktop opt-in above is platform-scoped precisely so
            // it can never reach that Apple host pass.
            sources: ["RecklessBridge.c", "RecklessHostStubs.c"],
            publicHeadersPath: "include",
            cSettings: sourceCSettings,
            linkerSettings: sourceLinkerSettings
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
        // Known-answer gate: asks positions whose answer is FORCED (two mates,
        // one only-legal-move) and checks that node counts grow with depth.
        // This is the "it plays chess" claim, which is strictly stronger than
        // both "it linked" (true of any build) and "it reports backend ==
        // .real" (RecklessBackendTests) — RecklessHostStubs.c makes those two
        // claims link-compatible with a no-op engine, so only a real search
        // separates them.
        //
        // Committed rather than inlined into a CI heredoc so the person a red
        // gate lands on can run exactly what CI ran:
        //
        //   bash Tools/verify-desktop-gate.sh            # both arms + margin
        //   swift run -c release reckless-known-answer   # the real arm alone
        //
        .executableTarget(
            name: "reckless-known-answer",
            dependencies: ["SwiftReckless"],
            path: "Sources/reckless-known-answer"
        ),
        .testTarget(
            name: "SwiftRecklessTests",
            dependencies: ["SwiftReckless"],
            path: "Tests/SwiftRecklessTests"
        ),
    ]
)
