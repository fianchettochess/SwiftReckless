#!/usr/bin/env bash
# Tools/build-android.sh
#
# Build the creckless Rust FFI crate for Android (via cargo-ndk),
# outputting the .so / .a files that the Fianchetto Android Gradle build
# can link via the Skip/SkipFuse native-lib mechanism.
#
# PREREQUISITES:
#   rustup target add \
#     aarch64-linux-android \
#     armv7-linux-androideabi \
#     x86_64-linux-android \
#     i686-linux-android
#   cargo install cargo-ndk
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
#                     and Chrome OS devices.  Reckless's scalar fallback activates
#                     automatically on CPUs without AVX2.
#
#   i686-linux-android (x86 — 32-bit emulator only; rarely needed):
#     +sse4.2,+popcnt — widest-safe x86 baseline; AVX2 is not safe to assume
#                       on 32-bit x86.
#
# The NNUE weight file (v60-7f587dfb.nnue) is fetched at runtime by
# RecklessNetworkLoader, never embedded in the APK.
#
# OUTPUT:
#   android-libs/
#     arm64-v8a/   libcreckless.a
#     armeabi-v7a/ libcreckless.a
#     x86_64/      libcreckless.a
#     x86/         libcreckless.a

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$REPO_ROOT/rust"
OUT_DIR="$REPO_ROOT/android-libs"

# Minimum Android API level.  21 = Android 5.0 Lollipop.
API="${ANDROID_API:-21}"

echo "==> Android NDK API level: $API"

cargo_ndk_build() {
    local abi="$1"
    local rust_target="$2"
    local features="$3"
    echo ""
    echo "==> cargo ndk --target $abi --platform $API -- build --release"
    echo "    RUSTFLAGS=\"-C target-feature=$features\""
    RUSTFLAGS="-C target-feature=$features" \
        cargo ndk \
            --manifest-path "$RUST_DIR/Cargo.toml" \
            --target "$abi" \
            --platform "$API" \
            -- build --release
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
find "$OUT_DIR" -name "*.a" | sort | while read f; do
    size=$(du -sh "$f" | cut -f1)
    echo "    $size  $f"
done
echo ""
echo "    Wire these into the Fianchetto Android Gradle build:"
echo "    sourceSets.main.jniLibs.srcDirs += ['<path>/android-libs']"
