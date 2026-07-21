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
#   watchos-arm64_32_arm64             — Apple Watch devices (arm64_32 for
#                                        watchOS 6+, arm64 for watchOS 26+)
#   watchos-arm64_x86_64-simulator     — watchOS Simulator (arm64 + x86_64)
#   xros-arm64                         — Apple Vision Pro (visionOS)
#   xros-arm64-simulator               — visionOS Simulator (arm64 only; Rust
#                                        has no x86_64 visionOS-sim target)
#
# RUST TOOLCHAIN TIERS:
#   * iOS / iOS-sim / macOS / Mac Catalyst are Rust TIER 2 (rustup targets),
#     built with the default (stable) toolchain.
#   * tvOS / watchOS / visionOS are Rust TIER 3 (no prebuilt std), built with a
#     NIGHTLY toolchain + `-Z build-std=std,panic_unwind` (compiles std from
#     source per target). `creckless` is a `staticlib` — archived objects, no
#     final link — so a tier-3 slice only needs to COMPILE (no per-platform
#     linker/SDK dance). Verified: the crate + std build cleanly this way.
#
# PER-ARCH PERFORMANCE FLAGS:
#   aarch64-*  : +neon                 (NEON is baseline on every Apple Silicon /
#                                       A-series chip; activates Reckless's
#                                       vectorized NNUE accumulator)
#   x86_64-*   : +avx2,+bmi2,+popcnt   (optimized Intel build; requires a
#                                       Haswell-class CPU or newer)
#
# OUTPUT: Frameworks/RecklessFFI.xcframework (committed on path-based `main`;
# release tags reference the archived asset by URL and checksum).

set -euo pipefail

# Prefer the conventional full Xcode bundle when the developer's global
# xcode-select still points at CommandLineTools. This is process-local and does
# not mutate their machine configuration; CI pins DEVELOPER_DIR explicitly.
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
MANIFEST="$RUST_DIR/Cargo.toml"

BUILD_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
BUILD_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
BUILD_TMP_DIR="${TMPDIR:-/tmp}"
BUILD_TMP_DIR="${BUILD_TMP_DIR%/}"

RUSTUP="$BUILD_CARGO_HOME/bin/rustup"; [ -x "$RUSTUP" ] || RUSTUP="$(command -v rustup)"
STABLE_TOOLCHAIN="${RUST_STABLE_TOOLCHAIN:-1.96.1}"
NIGHTLY_TOOLCHAIN="${RUST_NIGHTLY_TOOLCHAIN:-nightly-2026-07-21}"

# Cargo's encoded form keeps each rustc argument intact even when a checkout
# path contains spaces.  The broad home mapping must come first: rustc applies
# the last matching prefix, allowing the stable canonical roots below to win.
# These flags also reach the std crates compiled by nightly `-Z build-std`.
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

# Deployment floors — keep in lockstep with Package.swift's platforms so the
# emitted objects are usable down to the package minimums.
export IPHONEOS_DEPLOYMENT_TARGET=13.0
export MACOSX_DEPLOYMENT_TARGET=10.15
export TVOS_DEPLOYMENT_TARGET=13.0
export WATCHOS_DEPLOYMENT_TARGET=6.0
export XROS_DEPLOYMENT_TARGET=1.0

NEON="+neon"
X86="+avx2,+bmi2,+popcnt"

# Tier-2 targets (stable toolchain).
STABLE_TARGETS=(
  aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  aarch64-apple-darwin x86_64-apple-darwin
  aarch64-apple-ios-macabi x86_64-apple-ios-macabi
)
# Tier-3 targets (nightly + build-std).
STD_TARGETS=(
  aarch64-apple-tvos aarch64-apple-tvos-sim x86_64-apple-tvos
  arm64_32-apple-watchos aarch64-apple-watchos
  aarch64-apple-watchos-sim x86_64-apple-watchos-sim
  aarch64-apple-visionos aarch64-apple-visionos-sim
)

echo "==> Ensuring pinned toolchains + targets"
echo "    stable:  $STABLE_TOOLCHAIN"
echo "    nightly: $NIGHTLY_TOOLCHAIN"
"$RUSTUP" toolchain install "$STABLE_TOOLCHAIN" --profile minimal
for t in "${STABLE_TARGETS[@]}"; do
  "$RUSTUP" target add "$t" --toolchain "$STABLE_TOOLCHAIN"
done
"$RUSTUP" toolchain install "$NIGHTLY_TOOLCHAIN" --profile minimal
"$RUSTUP" component add rust-src --toolchain "$NIGHTLY_TOOLCHAIN"

cargo_stable() { CARGO_ENCODED_RUSTFLAGS="$(encoded_rustflags "$2")" \
                   "$RUSTUP" run "$STABLE_TOOLCHAIN" cargo build --locked --release \
                   --manifest-path "$MANIFEST" --target "$1"; }
cargo_std()    { CARGO_ENCODED_RUSTFLAGS="$(encoded_rustflags "$2")" \
                   "$RUSTUP" run "$NIGHTLY_TOOLCHAIN" cargo build --locked --release \
                   -Z build-std=std,panic_unwind --manifest-path "$MANIFEST" --target "$1"; }
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
WATCH_DEV="$(fat libcreckless-watchos.a          "$(LIB arm64_32-apple-watchos)"     "$(LIB aarch64-apple-watchos)")"
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

# The Rust compiler and its prebuilt standard libraries may retain their own
# public build-service paths. What must never escape is a path from this
# checkout, Cargo/rustup installation, or temporary build directory.
for local_root in "$REPO_ROOT" "$BUILD_CARGO_HOME" "$BUILD_RUSTUP_HOME" "$BUILD_TMP_DIR"; do
  case "$local_root" in ""|/|/tmp) continue ;; esac
  if LC_ALL=C grep -aR -F -l -- "$local_root" "$XCF" >/dev/null; then
    echo "error: local build path remains in $XCF: $local_root" >&2
    exit 1
  fi
done
