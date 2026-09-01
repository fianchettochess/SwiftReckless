#!/usr/bin/env bash
# Tools/build-desktop.sh
#
# Build the creckless Rust FFI crate for the DESKTOP targets — Linux (glibc) and
# Windows (MSVC) — producing the static archive that SwiftReckless's source arm
# links when the consumer sets SWIFTRECKLESS_LINK_ARCHIVE=1.
#
# This is the desktop sibling of Tools/build-android.sh. Same shape, same
# reproducible path remapping; the difference is only which triples and which
# SIMD baseline.
#
# WHY A SEPARATE ARCHIVE AT ALL. The Apple arm links a committed XCFramework and
# needs no Rust toolchain. Desktop cannot use that (it is Mach-O), and the
# archive is ~14-24 MB per target, so it is built on demand and never committed.
# Without one, the source arm links honest no-op stubs and says so
# (`RecklessBackend.current == .stub`).
#
# PREREQUISITES
#   rustup (the script installs the pinned toolchain and the requested target).
#   No system linker is needed: a `staticlib` is assembled by rustc's archiver,
#   so BOTH targets cross-build from any host — including macOS, which is how
#   the archives used to validate this path were produced.
#
# SIMD BASELINE. Matches the x86_64 Apple slices: AVX2 + BMI2 + POPCNT
# (Haswell-class, 2013+). Reckless selects its NNUE path at COMPILE time and has
# no runtime dispatch, so this is a hard hardware requirement of the output, not
# a preference. Override with RECKLESS_TARGET_FEATURES for a baseline build:
#   RECKLESS_TARGET_FEATURES=+popcnt bash Tools/build-desktop.sh
#
# USAGE
#   bash Tools/build-desktop.sh                 # host-native desktop target
#   bash Tools/build-desktop.sh linux windows windows-arm64
#
# OUTPUT (also printed, with the exact env the consumer needs)
#   rust/target/x86_64-unknown-linux-gnu/release/libcreckless.a
#   rust/target/x86_64-pc-windows-msvc/release/creckless.lib
#   rust/target/aarch64-pc-windows-msvc/release/creckless.lib

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$REPO_ROOT/rust"

BUILD_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
BUILD_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
BUILD_TMP_DIR="${TMPDIR:-/tmp}"
BUILD_TMP_DIR="${BUILD_TMP_DIR%/}"
RUSTUP="$BUILD_CARGO_HOME/bin/rustup"; [ -x "$RUSTUP" ] || RUSTUP="$(command -v rustup)"
STABLE_TOOLCHAIN="${RUST_STABLE_TOOLCHAIN:-1.96.1}"
# CPU BASELINE: HASWELL (2013) OR NEWER ON x86_64. DECIDED, NOT INHERITED.
#
# Reckless selects its SIMD at COMPILE time and performs no runtime dispatch, so
# an archive built with these features does not degrade on an older CPU — it
# executes an illegal instruction and the process dies with SIGILL. There is no
# graceful path, which is why this is a shipping decision rather than a tuning
# knob.
#
# The default matches build-xcframework.sh's Intel slice, but the reasoning is
# NOT the same and should not be quietly reused a third time. On Apple the
# baseline was free: every Mac in the supported range has AVX2. Desktop
# Windows and Linux reach a much broader population, so the owner made the call
# explicitly on 2026-08-08 — keep AVX2 and document the requirement:
#
#   * Windows: no practical exposure. Pre-Haswell parts predate TPM 2.0, so
#     those machines are not Windows 11 capable in the first place.
#   * Linux: the TPM argument does NOT apply — nothing stops a 2012 Linux
#     desktop. The exposure is real but small, and it is accepted on the
#     grounds that anyone still running such a machine can rebuild with a
#     lower baseline, which is exactly what the override below is for.
#
# To build for an older baseline:  RECKLESS_TARGET_FEATURES=+popcnt ./build-desktop.sh
# Expect a measurable strength loss; the engine is SIMD-bound.
# PER TARGET, because the baseline is an x86 statement. `+avx2,+bmi2,+popcnt`
# describes Haswell; on aarch64 those feature names do not exist and rustc
# accepts them with a warning rather than an error, which would leave an ARM
# archive built by a line that reads as though it had asked for something.
# NEON is mandatory in the aarch64 base ISA, so the ARM targets need no
# `target-feature` at all to get vectorised code.
#
# RECKLESS_TARGET_FEATURES still overrides, for every target, unchanged.
features_for_triple() {
    if [ -n "${RECKLESS_TARGET_FEATURES+x}" ]; then
        printf '%s' "$RECKLESS_TARGET_FEATURES"
        return
    fi
    case "$1" in
        x86_64-*)  printf '%s' "+avx2,+bmi2,+popcnt" ;;
        aarch64-*) printf '%s' "" ;;
        *)         printf '%s' "" ;;
    esac
}

# CARGO_ENCODED_RUSTFLAGS keeps paths with spaces intact. Broad home mapping
# first so the more specific roots take precedence (mirrors build-android.sh).
encoded_rustflags() {
    local features="$1"
    local -a flags=()
    # An empty feature string must produce NO flag rather than an empty one:
    # `-C target-feature=` is accepted but says nothing, and printing it would
    # imply a baseline was chosen when none was.
    if [ -n "$features" ]; then
        flags+=(-C "target-feature=$features")
    fi
    flags+=(
        "--remap-path-prefix=$HOME=/build/user"
        "--remap-path-prefix=$BUILD_TMP_DIR=/build/tmp"
        "--remap-path-prefix=$BUILD_CARGO_HOME=/build/cargo"
        "--remap-path-prefix=$BUILD_RUSTUP_HOME=/build/rustup"
        "--remap-path-prefix=$REPO_ROOT=/src/SwiftReckless"
    )
    local IFS=$'\x1f'
    printf '%s' "${flags[*]}"
}

resolve_triple() {
    case "$1" in
        linux|x86_64-unknown-linux-gnu)   echo "x86_64-unknown-linux-gnu" ;;
        windows|x86_64-pc-windows-msvc)   echo "x86_64-pc-windows-msvc" ;;
        windows-arm64|aarch64-pc-windows-msvc) echo "aarch64-pc-windows-msvc" ;;
        *) echo "error: unknown desktop target '$1'" >&2
           echo "       (use: linux | windows | windows-arm64)" >&2; exit 2 ;;
    esac
}

if [ "$#" -gt 0 ]; then
    REQUESTED=("$@")
else
    case "$(uname -s)" in
        Linux)                 REQUESTED=("linux") ;;
        MINGW*|MSYS*|CYGWIN*)
            # Arch-aware: a Windows-on-ARM host defaulting to the x86_64 target
            # would silently build an archive it cannot run, and the gate that
            # follows would then be testing emulation without saying so.
            case "$(uname -m)" in
                aarch64|arm64) REQUESTED=("windows-arm64") ;;
                *)             REQUESTED=("windows") ;;
            esac ;;
        *) echo "error: no host-native desktop target on $(uname -s) $(uname -m); name one explicitly:" >&2
           echo "  bash Tools/build-desktop.sh linux windows windows-arm64" >&2; exit 2 ;;
    esac
fi

echo "==> Ensuring pinned Rust $STABLE_TOOLCHAIN"
"$RUSTUP" toolchain install "$STABLE_TOOLCHAIN" --profile minimal

build_target() {
    local triple; triple="$(resolve_triple "$1")"
    echo ""
    echo "==> rustup target add $triple"
    "$RUSTUP" target add "$triple" --toolchain "$STABLE_TOOLCHAIN"
    local features; features="$(features_for_triple "$triple")"
    echo "==> cargo build --release --target $triple"
    echo "    target features: ${features:-<none: base ISA>} (build paths remapped)"
    # --print native-static-libs is not decoration: it is the authoritative list
    # of what the final link needs alongside this archive, and Package.swift's
    # desktop linkerSettings are transcribed from it. If a Rust or engine
    # upgrade changes this line, those settings must change with it.
    CARGO_ENCODED_RUSTFLAGS="$(encoded_rustflags "$features")$(printf '\x1f--print\x1fnative-static-libs')" \
        "$RUSTUP" run "$STABLE_TOOLCHAIN" cargo build \
            --manifest-path "$RUST_DIR/Cargo.toml" \
            --locked --release --target "$triple"

    local dir="$RUST_DIR/target/$triple/release"
    local archive
    case "$triple" in
        *windows-msvc) archive="$dir/creckless.lib" ;;
        *)             archive="$dir/libcreckless.a" ;;
    esac
    if [ ! -f "$archive" ]; then
        echo "error: expected archive not produced: $archive" >&2
        exit 1
    fi
    echo "    -> $archive  ($(du -h "$archive" | cut -f1))"

    echo ""
    echo "    Link it into a SwiftPM build with:"
    echo "      export SWIFTRECKLESS_LINK_ARCHIVE=1"
    case "$triple" in
        *windows-msvc)
            echo "      swift build -Xlinker /LIBPATH:$dir"
            echo "      (Prefer /LIBPATH:. Defining LIB outside a Visual Studio developer"
            echo "       prompt stops clang auto-detecting the MSVC/Windows SDK lib dirs and"
            echo "       breaks the link on msvcrt.lib / oldnames.lib / msvcprt.lib.)" ;;
        *)
            echo "      export LIBRARY_PATH=$dir"
            echo "      (or: swift build -Xlinker -L$dir)" ;;
    esac
    echo "    Then confirm what you actually linked (do not assume):"
    echo "      SWIFTRECKLESS_EXPECT_BACKEND=real swift test --filter RecklessBackendTests"
}

for t in "${REQUESTED[@]}"; do
    build_target "$t"
done

echo ""
echo "==> Done. These are static LINK INPUTS, not loadable libraries."
