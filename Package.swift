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
//   CReckless         — C interop layer.  On Apple hosts in PATH MODE this
//                       compiles the thin C bridge (`RecklessIO.h` +
//                       `RecklessBridge.c`) and links the pre-built static
//                       library `libcreckless.a` via a `binaryTarget`.  The
//                       static lib is the Rust FFI crate at `rust/` built for
//                       the target arch with `cargo build --release` (see
//                       Tools/build-xcframework.sh for the full recipe).  On
//                       non-Apple hosts (Linux / Android) the same C bridge
//                       compiles but the Rust lib must be provided externally
//                       (see the TODO in the README and `linkerSettings` below).
//
//   SwiftReckless      — Swift-facing API: `RecklessEngine` (mirrors
//                       `StockfishEngine`), `RecklessNetworkLoader` (fetches
//                       the NNUE net at runtime, never committed to the repo).
//
//   SwiftRecklessTests — offline unit tests + (gated) integration tests.
//
// BUILD STATUS (scaffold — see README "Status" section):
//   * CReckless compiles on macOS once `libcreckless.a` exists at the path
//     referenced by the binaryTarget below.  Run `Tools/build-macos.sh` first.
//   * The Rust crate at `rust/` builds with `cargo build --release` (macOS
//     host) but is STUBBED — it does not yet vendor/depend on the Reckless
//     crate itself.  Wire that dependency in `rust/Cargo.toml` and supply the
//     NNUE net (see README) before using in production.
//   * Android: requires `cargo-ndk`; see README for the exact commands.
//
// PATH MODE on `main` (just like SwiftStockfish): `binaryTarget` points to
// `Frameworks/RecklessFFI.xcframework` checked in alongside this manifest.
// Once the xcframework is built and committed, `swift build` works with no
// extra steps.  At release time CI rewrites the binaryTarget to url+checksum.

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
// caller-supplied-lib path (useful for CI that builds the Rust crate first).
let useBinaryEngine = hostIsApple
    && Context.environment["SWIFTRECKLESS_FORCE_SOURCE_BUILD"] != "1"

// ── Engine targets ────────────────────────────────────────────────────────────
let engineTargets: [Target]
if useBinaryEngine {
    // APPLE PATH: link the prebuilt xcframework + compile the thin C bridge.
    // TODO: replace the `path:` binaryTarget with `url:` + `checksum:` at
    // release time (same pattern as SwiftStockfish).
    engineTargets = [
        .binaryTarget(
            name: "RecklessFFI",
            // Built by Tools/build-xcframework.sh; not yet checked in.
            // The xcframework carries three slices:
            //   ios-arm64
            //   ios-arm64_x86_64-simulator
            //   macos-arm64_x86_64
            // TODO: run Tools/build-xcframework.sh and commit the result.
            path: "Frameworks/RecklessFFI.xcframework"
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
    // placed at the path referenced by RECKLESS_LIB_DIR, then linked manually
    // via linkerSettings.  This is the path taken by the Android (Skip) build.
    //
    // Typical invocation:
    //   RECKLESS_LIB_DIR=/path/to/rust/target/aarch64-linux-android/release \
    //   swift build
    //
    // TODO: wire RECKLESS_LIB_DIR into Package.swift once the Rust crate is
    // production-ready (needs the reckless engine dependency vendored).
    engineTargets = [
        .target(
            name: "CReckless",
            path: "Sources/CReckless",
            sources: ["RecklessBridge.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ],
            linkerSettings: [
                // Link the locally-built Rust static library by passing its
                // absolute path directly to the linker.  This is more reliable
                // than -L/-l on Apple's ld, which can silently skip the .a
                // when the Swift driver passes flags via clang's -Xlinker.
                // Build the .a first:
                //   cargo build --release --manifest-path rust/Cargo.toml
                // Then:
                //   SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 swift build
                .unsafeFlags([
                    "/build/user_/Documents/SwiftReckless/rust/target/release/libcreckless.a",
                    "-lc++",
                ]),
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
        // bestmove.  Run as an executable (not a test) because the Reckless
        // Rust engine hijacks process-global fd 1 (stdout), which collides
        // with the XCTest capture harness.  All output goes to stderr.
        //
        // Usage:
        //   SWIFTRECKLESS_FORCE_SOURCE_BUILD=1 \
        //   swift run --package-path /build/user_/Documents/SwiftReckless reckless-smoke
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
