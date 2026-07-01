#!/usr/bin/env bash
# Tools/build-macos.sh
#
# Build the creckless Rust static library for macOS (arm64 + x86_64),
# then lipo them into a universal fat library and place it where
# SwiftPM's binaryTarget expects it.
#
# PREREQUISITES:
#   rustup target add x86_64-apple-darwin aarch64-apple-darwin
#   cargo (1.79+)
#
# PERFORMANCE FLAGS:
#   arm64 (Apple Silicon): NEON is always available; enable it explicitly.
#     RUSTFLAGS="-C target-feature=+neon,+fp16,+dotprod" for M-series CPUs.
#     We use +neon (safe universal Apple Silicon baseline) so the fat lib
#     works on A-series chips too.
#   x86_64:  AVX2 + BMI2 + POPCNT for Reckless's NNUE vectorisation.
#     Matching the SIMD flags used by Stockfish's build-xcframework.sh for
#     the x86_64 simulator slice.  On older Macs without AVX2 the scalar
#     fallback inside Reckless activates automatically (Reckless detects at
#     runtime via CPUID), so this is safe.
#
# OUTPUT:
#   Frameworks/RecklessFFI.xcframework  (consumed by Package.swift binaryTarget)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$REPO_ROOT/rust"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"

echo "==> Building creckless for macOS arm64 ..."
RUSTFLAGS="-C target-feature=+neon" \
    cargo build --release \
    --manifest-path "$RUST_DIR/Cargo.toml" \
    --target aarch64-apple-darwin

echo "==> Building creckless for macOS x86_64 ..."
RUSTFLAGS="-C target-feature=+avx2,+bmi2,+popcnt" \
    cargo build --release \
    --manifest-path "$RUST_DIR/Cargo.toml" \
    --target x86_64-apple-darwin

# Lipo into a fat lib.
ARM64_LIB="$RUST_DIR/target/aarch64-apple-darwin/release/libcreckless.a"
X86_LIB="$RUST_DIR/target/x86_64-apple-darwin/release/libcreckless.a"
FAT_LIB="$RUST_DIR/target/libcreckless-macos.a"

echo "==> Lipo arm64 + x86_64 → universal macOS lib ..."
lipo -create "$ARM64_LIB" "$X86_LIB" -output "$FAT_LIB"

# Build the xcframework (macOS slice only for now; iOS slices added by build-xcframework.sh).
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$FRAMEWORKS_DIR/RecklessFFI.xcframework"
xcodebuild -create-xcframework \
    -library "$FAT_LIB" \
    -headers "$REPO_ROOT/Sources/CReckless/include" \
    -output "$FRAMEWORKS_DIR/RecklessFFI.xcframework"

echo "==> Done: $FRAMEWORKS_DIR/RecklessFFI.xcframework"
echo "    Now run: swift build"
