#!/bin/bash
#
# Select Xcode 26.x and validate the capabilities required to rebuild
# SwiftReckless's Apple binary.
#
# Release reproducibility depends on the Xcode and Swift major lines plus the
# Intel instruction-set floor baked into the XCFramework (Rust target features
# +avx2,+bmi2,+popcnt, selected at compile time with no runtime dispatch).
# Patch-level Xcode, build, and Swift versions may advance without changing
# that contract.
#
# The script is runner-neutral, so moving the macOS jobs between GitHub-hosted
# and self-hosted Intel Macs is a `runs-on` change only:
#
#   * A DEVELOPER_DIR already in the environment is an explicit pin and wins.
#   * Otherwise the newest /Applications/Xcode_26.N[.N].app is chosen. That is
#     how GitHub-hosted images install Xcode (several side by side), and taking
#     the newest 26.x keeps the patch-level-tolerant rule above. Beta and
#     release-candidate bundles never match the strictly numeric name.
#   * Otherwise /Applications/Xcode.app is used (a single-Xcode Mac).
#
# Whatever is chosen must still report Xcode 26.x with Apple Swift 6.x, and
# the CPU must provide AVX2, BMI2 and POPCNT, or the run fails. Under GitHub
# Actions the choice is exported through GITHUB_ENV so every later step uses
# it.
#
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

select_developer_dir() {
  if [ -n "${DEVELOPER_DIR:-}" ]; then
    printf '%s\n' "$DEVELOPER_DIR"
    return
  fi
  local app name best=''
  best="$(
    for app in /Applications/Xcode_26*.app; do
      [ -d "$app" ] || continue
      name="$(basename "$(cd "$app" && pwd -P)")"
      if [[ "$name" =~ ^Xcode_(26(\.[0-9]+)*)\.app$ ]]; then
        printf '%s %s\n' "${BASH_REMATCH[1]}" "/Applications/$name"
      fi
    done | sort -u -V -k1,1 | tail -n 1 | cut -d' ' -f2-
  )"
  if [ -n "$best" ]; then
    printf '%s\n' "$best/Contents/Developer"
  else
    printf '%s\n' /Applications/Xcode.app/Contents/Developer
  fi
}

if [ "$(uname -m)" != "x86_64" ]; then
  fail "the Apple binary must be rebuilt on x86_64"
fi

RK_DEVELOPER_DIR="$(select_developer_dir)"
if [ ! -d "$RK_DEVELOPER_DIR" ]; then
  fail "full Xcode developer directory not found at $RK_DEVELOPER_DIR"
fi
echo "selected DEVELOPER_DIR=$RK_DEVELOPER_DIR"

XCODE_VERSION="$(DEVELOPER_DIR="$RK_DEVELOPER_DIR" xcodebuild -version)"
SWIFT_VERSION="$(DEVELOPER_DIR="$RK_DEVELOPER_DIR" xcrun swift --version)"
XCODE_PRODUCT_LINE="$(printf '%s\n' "$XCODE_VERSION" | sed -n '1p')"
XCODE_BUILD_LINE="$(printf '%s\n' "$XCODE_VERSION" | sed -n '2p')"

printf '%s\n' "$XCODE_VERSION"
printf '%s\n' "$SWIFT_VERSION"

if ! grep -Eq '^Xcode 26([.][0-9]+)*([[:space:]].*)?$' \
  <<< "$XCODE_PRODUCT_LINE"; then
  fail "Xcode 26.x is required (found: $XCODE_PRODUCT_LINE)"
fi
if ! grep -Eq '^Build version [^[:space:]]+$' <<< "$XCODE_BUILD_LINE"; then
  fail "xcodebuild did not report a full Xcode build version"
fi
if ! grep -Eq 'Apple Swift version 6([.]|[[:space:](]|$)' \
  <<< "$SWIFT_VERSION"; then
  fail "an Apple Swift 6.x toolchain is required"
fi

MACOS_SDK="$(DEVELOPER_DIR="$RK_DEVELOPER_DIR" xcrun \
  --sdk macosx --show-sdk-path)"
if [ ! -d "$MACOS_SDK" ]; then
  fail "the selected Xcode does not provide a macOS SDK"
fi

LEAF7_FEATURES="$(sysctl -n machdep.cpu.leaf7_features)"
if ! grep -qw AVX2 <<< "$LEAF7_FEATURES"; then
  fail "the build host CPU does not provide AVX2"
fi
if ! grep -qw BMI2 <<< "$LEAF7_FEATURES"; then
  fail "the build host CPU does not provide BMI2"
fi
BASE_FEATURES="$(sysctl -n machdep.cpu.features)"
if ! grep -qw POPCNT <<< "$BASE_FEATURES"; then
  fail "the build host CPU does not provide POPCNT"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "DEVELOPER_DIR=$RK_DEVELOPER_DIR" >> "$GITHUB_ENV"
fi

echo "verified: full Xcode 26.x with Apple Swift 6.x"
echo "verified: x86_64 build host with AVX2/BMI2/POPCNT"
