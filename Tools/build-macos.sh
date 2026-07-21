#!/usr/bin/env bash
# Tools/build-macos.sh
#
# Build the creckless Rust static library for macOS (arm64 + x86_64),
# then lipo them into a universal fat library and place it where
# SwiftPM's binaryTarget expects it.
#
# PREREQUISITES:
#   rustup (the script installs pinned Rust 1.96.1 and both macOS targets)
#   full Xcode
#
# PERFORMANCE FLAGS:
#   arm64 (Apple Silicon): NEON is always available; enable it explicitly.
#     RUSTFLAGS="-C target-feature=+neon,+fp16,+dotprod" for M-series CPUs.
#     We use +neon (safe universal Apple Silicon baseline) so the fat lib
#     works on A-series chips too.
#   x86_64: AVX2 + BMI2 + POPCNT for Reckless's NNUE vectorisation. Reckless
#     chooses this implementation at compile time and does not runtime-dispatch,
#     so the Intel slice requires a Haswell-class CPU or newer.
#
# OUTPUT:
#   Frameworks/RecklessFFI.xcframework  (consumed by Package.swift binaryTarget)

set -euo pipefail
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
    echo "error: full Xcode is required (set DEVELOPER_DIR to its Developer directory)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$REPO_ROOT/rust"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"

BUILD_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
BUILD_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
BUILD_TMP_DIR="${TMPDIR:-/tmp}"
BUILD_TMP_DIR="${BUILD_TMP_DIR%/}"
RUSTUP="$BUILD_CARGO_HOME/bin/rustup"; [ -x "$RUSTUP" ] || RUSTUP="$(command -v rustup)"
STABLE_TOOLCHAIN="${RUST_STABLE_TOOLCHAIN:-1.96.1}"

# Preserve rustc argument boundaries for paths containing spaces and replace
# developer-machine roots in panic locations, object data, and debug metadata.
encoded_rustflags() {
    local target_features="$1"
    local -a flags=(
        -C "target-feature=$target_features"
        "--remap-path-prefix=$HOME=/build/user"
        "--remap-path-prefix=$BUILD_TMP_DIR=/build/tmp"
        "--remap-path-prefix=$BUILD_CARGO_HOME=/build/cargo"
        "--remap-path-prefix=$BUILD_RUSTUP_HOME=/build/rustup"
        "--remap-path-prefix=$REPO_ROOT=/src/SwiftReckless"
    )
    local IFS=$'\x1f'
    printf '%s' "${flags[*]}"
}

echo "==> Ensuring pinned Rust $STABLE_TOOLCHAIN + macOS targets ..."
"$RUSTUP" toolchain install "$STABLE_TOOLCHAIN" --profile minimal
"$RUSTUP" target add aarch64-apple-darwin x86_64-apple-darwin \
    --toolchain "$STABLE_TOOLCHAIN"

echo "==> Building creckless for macOS arm64 ..."
CARGO_ENCODED_RUSTFLAGS="$(encoded_rustflags "+neon")" \
    "$RUSTUP" run "$STABLE_TOOLCHAIN" cargo build --locked --release \
    --manifest-path "$RUST_DIR/Cargo.toml" \
    --target aarch64-apple-darwin

echo "==> Building creckless for macOS x86_64 ..."
CARGO_ENCODED_RUSTFLAGS="$(encoded_rustflags "+avx2,+bmi2,+popcnt")" \
    "$RUSTUP" run "$STABLE_TOOLCHAIN" cargo build --locked --release \
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
