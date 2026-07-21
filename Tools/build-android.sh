#!/usr/bin/env bash
# Tools/build-android.sh
#
# Build the creckless Rust FFI crate for Android (via cargo-ndk), producing one
# static `.a` archive per ABI for the final native link. These are link-time
# inputs, not loadable JNI `.so` libraries and must not be placed in `jniLibs`.
#
# PREREQUISITES:
#   rustup (the script installs pinned Rust 1.96.1 and all Android targets)
#   cargo install cargo-ndk --version 4.1.2 --locked
#   Android NDK r26+ installed; NDK_HOME or ANDROID_NDK_ROOT set.
#
# PERFORMANCE FLAGS (per-arch):
#
#   aarch64-linux-android (arm64-v8a — primary Android target, ~95% of devices):
#     +neon       — always present on ARMv8-A; enables Reckless's vectorised
#                   NNUE path.  On modern mid-high range devices (Cortex-A76+,
#                   Snapdragon 8xx), consider also passing:
#                     +dotprod,+fp16
#                   for additional throughput on the NNUE dot-product loops.
#
#   armv7-linux-androideabi (armeabi-v7a — 32-bit legacy; include for broad compat):
#     +neon       — present on virtually all ARMv7 Android devices (required
#                   by the Android CDD since API 21).
#     +vfpv3      — VFP v3 FPU; available alongside NEON on ARMv7.
#
#   x86_64-linux-android (x86_64 — emulator, Chrome OS):
#     +avx2,+popcnt — AVX2 SIMD, widely available on x86_64 Android emulators
#                     and newer Chrome OS devices. Reckless selects this path at
#                     compile time, so this binary requires AVX2 hardware.
#
#   i686-linux-android (x86 — 32-bit emulator only; rarely needed):
#     +sse4.2,+popcnt — optimized 32-bit build; requires both features.
#
# The NNUE weight file (v54-5478683c.nnue) is fetched at runtime by
# RecklessNetworkLoader, never embedded in the APK.
#
# OUTPUT:
#   android-libs/
#     arm64-v8a/   libcreckless.a
#     armeabi-v7a/ libcreckless.a
#     x86_64/      libcreckless.a
#     x86/         libcreckless.a

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$REPO_ROOT/rust"
OUT_DIR="$REPO_ROOT/android-libs"

BUILD_CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
BUILD_RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
BUILD_TMP_DIR="${TMPDIR:-/tmp}"
BUILD_TMP_DIR="${BUILD_TMP_DIR%/}"
RUSTUP="$BUILD_CARGO_HOME/bin/rustup"; [ -x "$RUSTUP" ] || RUSTUP="$(command -v rustup)"
STABLE_TOOLCHAIN="${RUST_STABLE_TOOLCHAIN:-1.96.1}"
CARGO_NDK_VERSION="${CARGO_NDK_VERSION:-4.1.2}"

# CARGO_ENCODED_RUSTFLAGS survives cargo-ndk without splitting paths that
# contain spaces.  Put the broad home mapping first so the more specific,
# reproducible Cargo, rustup, temporary, and source roots take precedence.
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

# Minimum Android API level.  21 = Android 5.0 Lollipop.
API="${ANDROID_API:-21}"

echo "==> Ensuring pinned Rust $STABLE_TOOLCHAIN + Android targets"
"$RUSTUP" toolchain install "$STABLE_TOOLCHAIN" --profile minimal
"$RUSTUP" target add \
    aarch64-linux-android armv7-linux-androideabi \
    x86_64-linux-android i686-linux-android \
    --toolchain "$STABLE_TOOLCHAIN"
if [ "$("$RUSTUP" run "$STABLE_TOOLCHAIN" cargo ndk --version)" != "cargo-ndk $CARGO_NDK_VERSION" ]; then
    echo "error: install cargo-ndk $CARGO_NDK_VERSION with:" >&2
    echo "  cargo install cargo-ndk --version $CARGO_NDK_VERSION --locked" >&2
    exit 1
fi

echo "==> Android NDK API level: $API"

cargo_ndk_build() {
    local abi="$1"
    local rust_target="$2"
    local features="$3"
    echo ""
    echo "==> cargo ndk --target $abi --platform $API -- build --release"
    echo "    target features: $features (build paths remapped)"
    CARGO_ENCODED_RUSTFLAGS="$(encoded_rustflags "$features")" \
        "$RUSTUP" run "$STABLE_TOOLCHAIN" cargo ndk \
            --manifest-path "$RUST_DIR/Cargo.toml" \
            --target "$abi" \
            --platform "$API" \
            -- build --locked --release
    local lib="$RUST_DIR/target/$rust_target/release/libcreckless.a"
    mkdir -p "$OUT_DIR/$abi"
    cp "$lib" "$OUT_DIR/$abi/libcreckless.a"
    echo "    -> $OUT_DIR/$abi/libcreckless.a"
}

cargo_ndk_build "arm64-v8a"    "aarch64-linux-android"    "+neon"
cargo_ndk_build "armeabi-v7a"  "armv7-linux-androideabi"  "+neon,+vfpv3"
cargo_ndk_build "x86_64"       "x86_64-linux-android"     "+avx2,+popcnt"
cargo_ndk_build "x86"          "i686-linux-android"       "+sse4.2,+popcnt"

echo ""
echo "==> Done.  Built libs:"
find "$OUT_DIR" -name "*.a" | sort | while read -r f; do
    size=$(du -sh "$f" | cut -f1)
    echo "    $size  $f"
done
echo ""
echo "    These are static link inputs. Link the selected ABI archive into the"
echo "    final native shared library/executable; do not package .a files as jniLibs."
