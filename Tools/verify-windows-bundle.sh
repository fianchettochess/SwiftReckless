#!/usr/bin/env bash
# Tools/verify-windows-bundle.sh
#
# THE BUNDLE GATE. Asserts that a Windows consumer gets a REAL engine from a
# plain `swift build` — no SWIFTRECKLESS_LINK_ARCHIVE, no linker search path, no
# Rust toolchain — once Frameworks/RecklessWindowsFFI.artifactbundle is present.
#
# This is a DIFFERENT question from Tools/verify-desktop-gate.sh and both are
# worth having. That one asks "does the opt-in path link a real engine", by
# building two arms and asserting the margin. This one asks "is a real engine
# now the DEFAULT", which is the thing the bundle exists to change and the thing
# no other check would notice breaking.
#
# THE ASSERTION THAT MATTERS IS THE `Copying` LINE, and it is not decoration.
# SwiftPM matches an artifact variant on `supportedTriples`, and a mismatch is
# skipped with NO diagnostic — measured 2026-09-01 against a throwaway package
# on Swift 6.2.4. cargo emits `x86_64-pc-windows-msvc` while SwiftPM matches
# `x86_64-unknown-windows-msvc`, so a one-word vendor error produces a bundle
# that is present, well-formed, and silently ignored.
#
# In this package that would normally surface as an undefined-symbol link error,
# because the Windows binary arm deliberately does not compile
# RecklessHostStubs.c. But relying on that is relying on the stubs staying
# absent forever. `Copying creckless.lib` is SwiftPM saying, in its own words,
# that it selected the variant — so this check fails at the cause rather than at
# a symptom two layers down.
#
#     bash Tools/verify-windows-bundle.sh
#
# PREREQUISITES: a Windows host (running the engine is the point), a Swift
# toolchain, and rustup if the bundle has to be built.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

BUNDLE="Frameworks/RecklessWindowsFFI.artifactbundle"
SCRATCH="$REPO_ROOT/.build-bundle-gate"
LOG_DIR="${RECKLESS_GATE_LOG_DIR:-$REPO_ROOT/.build-gate-logs}"
BUILD_LOG="$LOG_DIR/bundle-build.log"
RUN_LOG="$LOG_DIR/bundle-run.log"

FAILURES=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
pass() { printf '    PASS  %s\n' "$*"; }
fail() { printf '    FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# ─────────────────────────────────────────────────────────────────────────────
# 0. Host
# ─────────────────────────────────────────────────────────────────────────────
say "Host"
OS="$(uname -s)"
case "$OS" in
    MINGW*|MSYS*|CYGWIN*) : ;;
    *) echo "error: this gate must run on Windows; the point is running the engine." >&2
       echo "       The bundle itself cross-builds anywhere: Tools/build-windows-artifactbundle.sh" >&2
       exit 2 ;;
esac
# uname -m reports the Git Bash binary's architecture, not the host's — Git for
# Windows ships x64 binaries that run emulated on ARM64. The OS string is the
# one signal Prism does not rewrite. See verify-desktop-gate.sh for the
# measurement.
case "$OS" in
    *ARM64*|*arm64*) HOST_ARCH="arm64"; WANT_TRIPLE="aarch64-unknown-windows-msvc" ;;
    *)               HOST_ARCH="x86_64"; WANT_TRIPLE="x86_64-unknown-windows-msvc" ;;
esac
info "host: $OS -> $HOST_ARCH"
info "expecting SwiftPM to select variant: $WANT_TRIPLE"
command -v swift >/dev/null 2>&1 || { echo "error: no swift on PATH" >&2; exit 2; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. The bundle
# ─────────────────────────────────────────────────────────────────────────────
say "Bundle"
if [ -f "$BUNDLE/info.json" ]; then
    info "already present: $BUNDLE"
else
    info "absent; building it"
    bash Tools/build-windows-artifactbundle.sh
fi
[ -f "$BUNDLE/info.json" ] || { echo "error: $BUNDLE/info.json not produced" >&2; exit 1; }

# The variant for THIS host must exist, or the build below would take the source
# arm and this gate would pass while proving nothing about the bundle.
if grep -q "$WANT_TRIPLE" "$BUNDLE/info.json"; then
    pass "bundle declares a variant for $WANT_TRIPLE"
else
    fail "bundle declares NO variant for $WANT_TRIPLE — this host cannot be served by it"
    sed 's/^/    | /' "$BUNDLE/info.json"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. A plain build, with the opt-in explicitly REMOVED
# ─────────────────────────────────────────────────────────────────────────────
# `env -u` rather than merely not setting them: if the caller's environment
# already had these, this would quietly become the opt-in path and the gate
# would assert nothing about the bundle.
#
# --manifest-cache none because the manifest branches on the environment and on
# the bundle's presence, and SwiftPM's manifest cache is keyed on contents and
# toolchain, not on either of those.
say "Building reckless-known-answer with NO opt-in"
mkdir -p "$LOG_DIR"
rm -rf "$SCRATCH"
env -u SWIFTRECKLESS_LINK_ARCHIVE -u LIBRARY_PATH -u LIB \
    swift build -c release --product reckless-known-answer \
        --scratch-path "$SCRATCH" --manifest-cache none 2>&1 | tee "$BUILD_LOG"

BIN="$(env -u SWIFTRECKLESS_LINK_ARCHIVE -u LIBRARY_PATH -u LIB \
    swift build -c release --scratch-path "$SCRATCH" --manifest-cache none \
    --show-bin-path)/reckless-known-answer.exe"
info "binary: $BIN"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Did SwiftPM actually select the variant?
# ─────────────────────────────────────────────────────────────────────────────
say "Bundle consumption"
if grep -q "Copying creckless.lib" "$BUILD_LOG"; then
    pass "SwiftPM reported 'Copying creckless.lib' — the variant was selected"
else
    fail "SwiftPM never reported 'Copying creckless.lib'. The bundle is present and"
    fail "      well-formed but was NOT selected — check supportedTriples against"
    fail "      $WANT_TRIPLE. cargo says 'pc'; SwiftPM matches 'unknown', and the"
    fail "      mismatch is skipped without a word."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Does it play chess, and does it say so honestly?
# ─────────────────────────────────────────────────────────────────────────────
say "Running the default build (expected: known answers, exit 0)"
set +e
"$BIN" > "$RUN_LOG" 2>&1
RUN_EXIT=$?
set -e
sed 's/^/    | /' "$RUN_LOG"
info "exit: $RUN_EXIT"

[ "$RUN_EXIT" -eq 0 ] \
    && pass "default build answered every required known-answer check" \
    || fail "default build exited $RUN_EXIT — the bundle did not produce a working engine"

grep -q "backend: real" "$RUN_LOG" \
    && pass "reported 'backend: real'" \
    || fail "did not report 'backend: real' — RECKLESS_SOURCE_ARM may be leaking into the binary arm"

# Independent of anything the program chose to print.
HITS="$(grep -a -c 'Reckless 0\.9' "$BIN" || true)"
info "engine version string in binary: $HITS hit(s)"
[ "${HITS:-0}" -ge 1 ] \
    && pass "binary embeds the engine version string" \
    || fail "binary does NOT embed the engine version string — no engine was linked"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Verdict
# ─────────────────────────────────────────────────────────────────────────────
say "Verdict"
info "Logs: $BUILD_LOG, $RUN_LOG"
if [ "$FAILURES" -eq 0 ]; then
    printf '\n\033[1;32mPASS\033[0m — a plain `swift build` on %s links the prebuilt engine\n' "$HOST_ARCH"
    printf '       and it plays chess. No opt-in, no Rust toolchain.\n\n'
    exit 0
else
    printf '\n\033[1;31mFAIL\033[0m — %d assertion(s) failed.\n\n' "$FAILURES"
    exit 1
fi
