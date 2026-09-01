#!/usr/bin/env bash
# Tools/build-windows-artifactbundle.sh
#
# Assemble Frameworks/RecklessWindowsFFI.artifactbundle from the cross-built
# Windows archives, so a Windows consumer gets a REAL engine from a plain
# `swift build` with no opt-in and no Rust toolchain.
#
# WHY A BUNDLE AND NOT AN XCFRAMEWORK. `.xcframework` cannot carry a Windows
# slice — SwiftPM maps Windows triples to nil when matching xcframework
# platforms, so Frameworks/RecklessFFI.xcframework is structurally Apple-only
# and cannot be extended. SE-0482 `staticLibrary` artifact bundles are the
# supported mechanism for exactly this, and unlike `.unsafeFlags` they do not
# cost the package its version-pinnability.
#
# WHAT THE FORMAT NEEDS, measured rather than assumed (Swift 6.2.4, 2026-09-01,
# against a throwaway package):
#
#   * `staticLibraryMetadata` is OPTIONAL. A variant with only `path` and
#     `supportedTriples` links correctly. This bundle ships no headers, and that
#     is honest rather than lazy: RecklessBridge.c forward-declares every
#     rk_ffi_* symbol itself ("Declared here so this translation unit can link
#     them from the Rust staticlib without a separate header"), so a header in
#     the bundle would be a second, unread copy of an ABI that already has one
#     source of truth.
#
#   * THE TRIPLE VENDOR IS `unknown`, NOT `pc`, AND THIS IS THE SHARP EDGE.
#     cargo emits x86_64-pc-windows-msvc; SwiftPM matches against
#     x86_64-unknown-windows-msvc. A vendor mismatch is skipped with NO
#     diagnostic — measured: the build proceeds and fails later at the link with
#     undefined symbols, never mentioning the bundle or the triple.
#
#     For this package that failure mode is worse than it sounds, because
#     RecklessHostStubs.c defines link-compatible no-op rk_ffi_*. If the Windows
#     binary arm ever compiled those stubs, a silently-skipped variant would
#     link CLEANLY against no-ops and ship a dead engine reporting itself
#     healthy. The manifest's Windows binary arm therefore does not compile the
#     stubs at all, exactly as the Apple binary arm does not — which converts
#     that silent failure into an undefined-symbol link error.
#
# THE ARCHIVES CROSS-BUILD FROM ANY HOST. A Rust staticlib needs no linker, so
# both are produced on macOS in ~15s each; only RUNNING them needs Windows, and
# that is what Tools/verify-desktop-gate.sh asserts.
#
# NOT COMMITTED. This bundle is a RELEASE artifact and .gitignore excludes it.
# Two 13 MB archives per engine bump do not belong in git history when a release
# asset carries them just as well — the xcframework beside it is committed and
# already accounts for most of a 113 MiB pack, which is the argument rather than
# against it.
#
# So Package.swift takes the Windows binary arm only when this bundle is
# PRESENT. A clone without it behaves exactly as this package did before the
# bundle existed: the source arm, stubs unless SWIFTRECKLESS_LINK_ARCHIVE=1.
# Absence is a supported state, and running this script is what upgrades it.
#
# AGPL: the archives contain the engine, so this bundle is an AGPL-3.0 artifact
# on the same terms as Frameworks/RecklessFFI.xcframework.
#
#   bash Tools/build-windows-artifactbundle.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

BUNDLE="Frameworks/RecklessWindowsFFI.artifactbundle"

# The artifact version tracks the ENGINE, not the crate: rust/Cargo.toml says
# 0.1.0 for the FFI shim, while the thing consumers care about is the pinned
# fork tag. Read it from Cargo.lock so it cannot drift from what was built.
ENGINE_TAG="$(sed -n 's/.*Reckless\.git?tag=swiftreckless-v\([0-9][^#]*\)#.*/\1/p' rust/Cargo.lock | head -1)"
[ -n "$ENGINE_TAG" ] || { echo "error: could not read the engine fork tag from rust/Cargo.lock" >&2; exit 1; }

# triple-dir : cargo-target : swiftpm-triple
VARIANTS=(
    "x86_64-windows:x86_64-pc-windows-msvc:x86_64-unknown-windows-msvc"
    "arm64-windows:aarch64-pc-windows-msvc:aarch64-unknown-windows-msvc"
)

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

say "Engine version from rust/Cargo.lock: $ENGINE_TAG"

# Build any archive that is missing. Never reuse one silently: print what is
# reused so a stale archive is visible rather than assumed fresh.
for entry in "${VARIANTS[@]}"; do
    IFS=: read -r dir cargo_target _ <<< "$entry"
    archive="rust/target/$cargo_target/release/creckless.lib"
    if [ -f "$archive" ]; then
        echo "    reusing $archive ($(wc -c < "$archive" | tr -d ' ') bytes)"
    else
        say "Building $cargo_target"
        case "$cargo_target" in
            x86_64-pc-windows-msvc)  bash Tools/build-desktop.sh windows ;;
            aarch64-pc-windows-msvc) bash Tools/build-desktop.sh windows-arm64 ;;
        esac
    fi
    [ -f "$archive" ] || { echo "error: archive not produced: $archive" >&2; exit 1; }
done

say "Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"

VARIANT_JSON=""
for entry in "${VARIANTS[@]}"; do
    IFS=: read -r dir cargo_target swift_triple <<< "$entry"
    mkdir -p "$BUNDLE/$dir"
    cp "rust/target/$cargo_target/release/creckless.lib" "$BUNDLE/$dir/creckless.lib"
    bytes="$(wc -c < "$BUNDLE/$dir/creckless.lib" | tr -d ' ')"
    echo "    $dir/creckless.lib  $bytes bytes  -> $swift_triple"
    [ -n "$VARIANT_JSON" ] && VARIANT_JSON="$VARIANT_JSON,"
    VARIANT_JSON="$VARIANT_JSON
      {
        \"path\": \"$dir/creckless.lib\",
        \"supportedTriples\": [\"$swift_triple\"]
      }"
done

cat > "$BUNDLE/info.json" <<EOF
{
  "schemaVersion": "1.0",
  "artifacts": {
    "creckless": {
      "type": "staticLibrary",
      "version": "$ENGINE_TAG",
      "variants": [$VARIANT_JSON
      ]
    }
  }
}
EOF

say "Verifying the bundle describes what it contains"
FAIL=0
python3 - "$BUNDLE" <<'PY' || FAIL=1
import json, os, sys
bundle = sys.argv[1]
info = json.load(open(os.path.join(bundle, "info.json")))
assert info["schemaVersion"] == "1.0", info["schemaVersion"]
art = info["artifacts"]["creckless"]
assert art["type"] == "staticLibrary", art["type"]
seen = set()
for v in art["variants"]:
    p = os.path.join(bundle, v["path"])
    if not os.path.isfile(p):
        print(f"    MISSING {v['path']}"); raise SystemExit(1)
    for t in v["supportedTriples"]:
        # The whole point. cargo says `pc`; SwiftPM matches `unknown`, and a
        # mismatch is skipped without a word.
        if "-pc-" in t:
            print(f"    BAD TRIPLE {t}: SwiftPM matches the `unknown` vendor;"
                  f" a `pc` variant is silently skipped")
            raise SystemExit(1)
        if t in seen:
            print(f"    DUPLICATE TRIPLE {t}"); raise SystemExit(1)
        seen.add(t)
    print(f"    ok {v['path']} -> {', '.join(v['supportedTriples'])}")
print(f"    {len(art['variants'])} variant(s), version {art['version']}")
PY
[ "$FAIL" -eq 0 ] || { echo "error: bundle self-check failed" >&2; exit 1; }

say "Done"
echo "    $BUNDLE"
echo ""
echo "    A Windows consumer now links the real engine from a plain \`swift build\`."
echo "    Prove it rather than believing it:"
echo "      bash Tools/verify-desktop-gate.sh windows"
echo "      bash Tools/verify-desktop-gate.sh windows-arm64"
