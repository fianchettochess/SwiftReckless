#!/usr/bin/env bash
# Tools/build-xcframework.sh
#
# Build the creckless Rust FFI crate for all Apple slices and assemble a
# multi-arch xcframework for use as the SwiftPM `binaryTarget`.
#
# SLICES PRODUCED:
#   ios-arm64                     — physical iPhone/iPad (A-series, M-series iPad)
#   ios-arm64_x86_64-simulator    — Simulator: arm64 (M-chip Mac) + x86_64 (Intel Mac)
#   macos-arm64_x86_64            — macOS: Apple Silicon + Intel
#
# PERFORMANCE FLAGS (per-arch):
#
#   aarch64-apple-ios / aarch64-apple-darwin / aarch64-apple-ios-sim:
#     +neon       — NEON SIMD (always present on ARMv8-A, i.e. every Apple Silicon
#                   chip).  Activates Reckless's vectorised NNUE accumulator
#                   (`forward/vectorized.rs`) and avoids the scalar fallback.
#     We deliberately omit +dotprod / +fp16 to keep the binary compatible with
#     older A-series chips (A9+).  If you target A15+ only, add:
#       +dotprod,+fp16,+sve  for extra throughput.
#
#   x86_64-apple-darwin / x86_64-apple-ios-sim:
#     +avx2       — 256-bit SIMD; required by Reckless's vectorised path.
#     +bmi2       — PEXT/PDEP; used by Stockfish-style magic bitboard attacks
#                   (Reckless may use the same trick).
#     +popcnt     — Fast population-count; used heavily in move generation.
#     These are available on all Intel Macs (Haswell 2013+) and the Rosetta
#     x86_64 simulator on Apple Silicon.
#
# PREREQUISITES:
#   rustup target add \
#     aarch64-apple-ios \
#     aarch64-apple-ios-sim \
#     x86_64-apple-ios \
#     aarch64-apple-darwin \
#     x86_64-apple-darwin
#
# OUTPUT:
#   Frameworks/RecklessFFI.xcframework

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$REPO_ROOT/rust"
CARGO="$HOME/.cargo/bin/cargo"
[ -x "$CARGO" ] || CARGO="$(command -v cargo)"

build() {
    local target="$1"; shift
    local flags="$1"; shift
    echo "==> cargo build --release --target $target  RUSTFLAGS=\"$flags\""
    RUSTFLAGS="$flags" "$CARGO" build --release \
        --manifest-path "$RUST_DIR/Cargo.toml" \
        --target "$target"
}

# ── macOS ─────────────────────────────────────────────────────────────────────
build aarch64-apple-darwin "-C target-feature=+neon"
build x86_64-apple-darwin  "-C target-feature=+avx2,+bmi2,+popcnt"

MACOS_ARM="$RUST_DIR/target/aarch64-apple-darwin/release/libcreckless.a"
MACOS_X86="$RUST_DIR/target/x86_64-apple-darwin/release/libcreckless.a"
MACOS_FAT="$RUST_DIR/target/libcreckless-macos.a"
lipo -create "$MACOS_ARM" "$MACOS_X86" -output "$MACOS_FAT"
echo "==> lipo → $MACOS_FAT"

# ── iOS device ────────────────────────────────────────────────────────────────
build aarch64-apple-ios "-C target-feature=+neon"
IOS_ARM="$RUST_DIR/target/aarch64-apple-ios/release/libcreckless.a"

# ── iOS Simulator ─────────────────────────────────────────────────────────────
build aarch64-apple-ios-sim "-C target-feature=+neon"
build x86_64-apple-ios      "-C target-feature=+avx2,+bmi2,+popcnt"

IOS_SIM_ARM="$RUST_DIR/target/aarch64-apple-ios-sim/release/libcreckless.a"
IOS_SIM_X86="$RUST_DIR/target/x86_64-apple-ios/release/libcreckless.a"
IOS_SIM_FAT="$RUST_DIR/target/libcreckless-ios-sim.a"
lipo -create "$IOS_SIM_ARM" "$IOS_SIM_X86" -output "$IOS_SIM_FAT"
echo "==> lipo → $IOS_SIM_FAT"

# ── Assemble xcframework ──────────────────────────────────────────────────────
HEADERS="$REPO_ROOT/Sources/CReckless/include"
XCF="$REPO_ROOT/Frameworks/RecklessFFI.xcframework"

mkdir -p "$REPO_ROOT/Frameworks"
rm -rf "$XCF"

xcodebuild -create-xcframework \
    -library "$IOS_ARM"     -headers "$HEADERS" \
    -library "$IOS_SIM_FAT" -headers "$HEADERS" \
    -library "$MACOS_FAT"   -headers "$HEADERS" \
    -output "$XCF"

echo ""
echo "==> Done: $XCF"
echo "    Slices:"
for slice in "$XCF"/*/; do echo "      $(basename "$slice")"; done
echo ""
echo "    Next steps:"
echo "    1. swift build   # confirms SPM picks up the xcframework"
echo "    2. (release only) zip it, then:"
echo "       swift package compute-checksum Frameworks/RecklessFFI.xcframework.zip"
echo "       for the url: binaryTarget in a tagged release."
echo "    NOTE: the xcframework is gitignored — built on-demand, never committed."
