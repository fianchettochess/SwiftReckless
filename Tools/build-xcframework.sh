#!/usr/bin/env bash
# Tools/build-xcframework.sh
#
# Build the creckless Rust FFI crate for the FULL gamut of Apple slices and
# assemble Frameworks/RecklessFFI.xcframework for use as the SwiftPM
# `binaryTarget`. This mirrors SwiftStockfish's 10-slice xcframework so the
# package is compatible with the full Swift Package Index platform matrix
# (WASM excluded — Rust FFI + a UCI thread do not target wasm32).
#
# SLICES PRODUCED (10):
#   ios-arm64                          — iPhone/iPad (A/M-series)
#   ios-arm64_x86_64-simulator         — iOS Simulator (arm64 + x86_64)
#   macos-arm64_x86_64                 — macOS (Apple Silicon + Intel)
#   ios-arm64_x86_64-maccatalyst       — Mac Catalyst (arm64 + x86_64)
#   tvos-arm64                         — Apple TV
#   tvos-arm64_x86_64-simulator        — tvOS Simulator (arm64 + x86_64)
#   watchos-arm64                      — Apple Watch (Series 5+/watchOS 6)
#   watchos-arm64_x86_64-simulator     — watchOS Simulator (arm64 + x86_64)
#   xros-arm64                         — Apple Vision Pro (visionOS)
#   xros-arm64-simulator               — visionOS Simulator (arm64 only; Rust
#                                        has no x86_64 visionOS-sim target)
#
# RUST TOOLCHAIN TIERS:
#   * iOS / iOS-sim / macOS / Mac Catalyst are Rust TIER 2 (rustup targets),
#     built with the default (stable) toolchain.
#   * tvOS / watchOS / visionOS are Rust TIER 3 (no prebuilt std), built with a
#     NIGHTLY toolchain + `-Z build-std=std,panic_abort` (compiles std from
#     source per target). `creckless` is a `staticlib` — archived objects, no
#     final link — so a tier-3 slice only needs to COMPILE (no per-platform
#     linker/SDK dance). Verified: the crate + std build cleanly this way.
#
# PER-ARCH PERFORMANCE FLAGS:
#   aarch64-*  : +neon                 (NEON is baseline on every Apple Silicon /
#                                       A-series chip; activates Reckless's
#                                       vectorised NNUE accumulator)
#   x86_64-*   : +avx2,+bmi2,+popcnt   (present on all Intel Macs (Haswell 2013+)
#                                       and the Rosetta x86_64 simulator)
#
# OUTPUT: Frameworks/RecklessFFI.xcframework  (gitignored; built on-demand or in
# the release CI, never committed).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$REPO_ROOT/rust"
MANIFEST="$RUST_DIR/Cargo.toml"

RUSTUP="$HOME/.cargo/bin/rustup"; [ -x "$RUSTUP" ] || RUSTUP="$(command -v rustup)"
CARGO="$HOME/.cargo/bin/cargo";   [ -x "$CARGO" ]   || CARGO="$(command -v cargo)"

# Deployment floors — keep in lockstep with Package.swift's platforms so the
# emitted objects are usable down to the package minimums.
export IPHONEOS_DEPLOYMENT_TARGET=13.0
export MACOSX_DEPLOYMENT_TARGET=10.15
export TVOS_DEPLOYMENT_TARGET=13.0
export WATCHOS_DEPLOYMENT_TARGET=6.0
export XROS_DEPLOYMENT_TARGET=1.0

NEON="-C target-feature=+neon"
X86="-C target-feature=+avx2,+bmi2,+popcnt"

# Tier-2 targets (stable toolchain).
STABLE_TARGETS=(
  aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  aarch64-apple-darwin x86_64-apple-darwin
  aarch64-apple-ios-macabi x86_64-apple-ios-macabi
)
# Tier-3 targets (nightly + build-std).
STD_TARGETS=(
  aarch64-apple-tvos aarch64-apple-tvos-sim x86_64-apple-tvos
  aarch64-apple-watchos aarch64-apple-watchos-sim x86_64-apple-watchos-sim
  aarch64-apple-visionos aarch64-apple-visionos-sim
)

echo "==> Ensuring toolchains + targets"
for t in "${STABLE_TARGETS[@]}"; do "$RUSTUP" target add "$t" >/dev/null 2>&1 || true; done
"$RUSTUP" toolchain install nightly --profile minimal >/dev/null 2>&1 || true
"$RUSTUP" component add rust-src --toolchain nightly >/dev/null 2>&1 || true

cargo_stable() { RUSTFLAGS="$2" "$CARGO" build --release --manifest-path "$MANIFEST" --target "$1"; }
cargo_std()    { RUSTFLAGS="$2" "$RUSTUP" run nightly cargo build --release \
                   -Z build-std=std,panic_abort --manifest-path "$MANIFEST" --target "$1"; }
LIB() { printf '%s' "$RUST_DIR/target/$1/release/libcreckless.a"; }
flags_for() { case "$1" in x86_64-*) printf '%s' "$X86";; *) printf '%s' "$NEON";; esac; }

echo "==> Building tier-2 slices (stable)"
for t in "${STABLE_TARGETS[@]}"; do cargo_stable "$t" "$(flags_for "$t")"; done
echo "==> Building tier-3 slices (nightly -Z build-std)"
for t in "${STD_TARGETS[@]}"; do cargo_std "$t" "$(flags_for "$t")"; done

OUT="$RUST_DIR/target/xcf"; rm -rf "$OUT"; mkdir -p "$OUT"
fat() { local o="$OUT/$1"; shift; lipo -create "$@" -output "$o"; printf '%s' "$o"; }

IOS_DEV="$(LIB aarch64-apple-ios)"
IOS_SIM="$(fat libcreckless-ios-sim.a         "$(LIB aarch64-apple-ios-sim)"     "$(LIB x86_64-apple-ios)")"
MACOS="$(fat  libcreckless-macos.a            "$(LIB aarch64-apple-darwin)"      "$(LIB x86_64-apple-darwin)")"
CAT="$(fat    libcreckless-maccatalyst.a      "$(LIB aarch64-apple-ios-macabi)"  "$(LIB x86_64-apple-ios-macabi)")"
TVOS_DEV="$(LIB aarch64-apple-tvos)"
TVOS_SIM="$(fat libcreckless-tvos-sim.a       "$(LIB aarch64-apple-tvos-sim)"    "$(LIB x86_64-apple-tvos)")"
WATCH_DEV="$(LIB aarch64-apple-watchos)"
WATCH_SIM="$(fat libcreckless-watchos-sim.a   "$(LIB aarch64-apple-watchos-sim)" "$(LIB x86_64-apple-watchos-sim)")"
XROS_DEV="$(LIB aarch64-apple-visionos)"
XROS_SIM="$(LIB aarch64-apple-visionos-sim)"   # arm64-only (no x86_64 visionOS sim target)

HEADERS="$REPO_ROOT/Sources/CReckless/include"
XCF="$REPO_ROOT/Frameworks/RecklessFFI.xcframework"
mkdir -p "$REPO_ROOT/Frameworks"; rm -rf "$XCF"

echo "==> Assembling xcframework (10 slices)"
xcodebuild -create-xcframework \
  -library "$IOS_DEV"   -headers "$HEADERS" \
  -library "$IOS_SIM"   -headers "$HEADERS" \
  -library "$MACOS"     -headers "$HEADERS" \
  -library "$CAT"       -headers "$HEADERS" \
  -library "$TVOS_DEV"  -headers "$HEADERS" \
  -library "$TVOS_SIM"  -headers "$HEADERS" \
  -library "$WATCH_DEV" -headers "$HEADERS" \
  -library "$WATCH_SIM" -headers "$HEADERS" \
  -library "$XROS_DEV"  -headers "$HEADERS" \
  -library "$XROS_SIM"  -headers "$HEADERS" \
  -output "$XCF"

rm -rf "$OUT"
echo ""
echo "==> Done: $XCF"
echo "    Slices:"
for slice in "$XCF"/*/; do echo "      $(basename "$slice")"; done
