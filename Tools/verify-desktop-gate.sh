#!/usr/bin/env bash
# Tools/verify-desktop-gate.sh
#
# THE DESKTOP REAL-ARCHIVE GATE. Builds the Rust archive, then builds BOTH arms
# of the package from the SAME tree and asserts they behave DIFFERENTLY:
#
#     stub arm  (no opt-in)                     → refuses, non-zero exit
#     real arm  (SWIFTRECKLESS_LINK_ARCHIVE=1)  → plays chess, exit 0
#
# WHY BOTH ARMS, AND WHY THE MARGIN IS THE ASSERTION.
#
# Sources/CReckless/RecklessHostStubs.c supplies link-compatible no-op `rk_ffi_*`
# symbols. That is a deliberate feature (it keeps the Apple host-introspection
# pass linkable), and it is also this package's central hazard: "it linked" and
# "it plays chess" are genuinely different claims.
#
# A job that only ever built the REAL arm could not tell you the opt-in did
# anything. If SWIFTRECKLESS_LINK_ARCHIVE silently stopped being honoured — a
# manifest refactor, a SwiftPM change in how `Context.environment` is cached, a
# typo in the variable name — a real-arm-only job would go on passing against
# the stub forever, reporting green while testing nothing. So the negative
# control is not a nicety here; without it this script would prove nothing about
# the opt-in at all. Both arms are built, and the assertion is the MARGIN
# between them, not the outcome of the good one.
#
# WHAT IS ASSERTED HARD (any failure exits non-zero):
#   1. stub arm exits NON-ZERO and says "backend: stub"
#   2. real arm exits ZERO and says "backend: real"
#   3. the real binary contains the engine's version string; the stub does not
#   4. the real binary is materially larger than the stub binary
#   5. every [required] check inside reckless-known-answer — the two forced
#      mates, the only-legal-move reply, and strictly increasing node counts
#
# WHAT IS ADVISORY: the archive's exact size/sha256, and the opening-move
# canaries inside the harness. Both are recorded and printed against the
# 2026-08-10 proof, because a rustc patch bump legitimately changes archive
# bytes and an engine bump legitimately changes an opening preference. Hard
# gating on either turns a routine bump into a red build with a misleading
# message.
#
# RUN IT LOCALLY — this is the point of the file existing. CI calls this script
# and adds nothing but a runner, a cache and a net download, so a red gate is
# reproducible with:
#
#     bash Tools/verify-desktop-gate.sh
#
# PREREQUISITES: Linux x86_64 with rustup, a Swift toolchain, a C toolchain
# (cargo links the staticlib with `cc`), and the NNUE net staged at
# rust/networks/ (the script downloads and verifies it if missing).
#
# AGPL: this builds the AGPL-3.0 engine fork from the tag pinned in
# rust/Cargo.lock, via Tools/build-desktop.sh with cargo's `--locked`. Do not
# vendor engine source and do not re-pin here. The archive it produces is an
# AGPL-derived artifact: passing it between CI jobs is fine, publishing it as a
# release asset is not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

TRIPLE="x86_64-unknown-linux-gnu"
ARCHIVE_DIR="$REPO_ROOT/rust/target/$TRIPLE/release"
ARCHIVE="$ARCHIVE_DIR/libcreckless.a"

NET_NAME="v54-5478683c.nnue"
NET_SHA="5478683cb1bababde29ae8f29468a99846726548fc6a0ed54cac40ab6d38efbf"
NET_URL="https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/$NET_NAME"
NET_DIR="$REPO_ROOT/rust/networks"

# Recorded on 2026-08-10: Ubuntu 24.04 x86_64, Swift 6.3.3, SwiftReckless
# 703f92a, Rust 1.96.1, fork tag swiftreckless-v0.9.1 = de35beac.
RECORDED_ARCHIVE_BYTES=23699394
RECORDED_ARCHIVE_SHA=4050d065b04693b8e3f7652f587972208371ba016577c7f340a678da6e651007
RECORDED_REAL_BYTES=18751880
RECORDED_STUB_BYTES=13016520

# Separate scratch paths per arm. Not cosmetic: it guarantees the two arms
# cannot share a build plan, a manifest cache, or a linked binary, so "the stub
# arm" can never be the real arm's output under another name.
STUB_SCRATCH="$REPO_ROOT/.build-gate-stub"
REAL_SCRATCH="$REPO_ROOT/.build-gate-real"
LOG_DIR="${RECKLESS_GATE_LOG_DIR:-$REPO_ROOT/.build-gate-logs}"

FAILURES=0
say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
pass() { printf '    PASS  %s\n' "$*"; }
warn() { printf '    WARN  %s\n' "$*"; }
fail() { printf '    FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

size_of() { wc -c < "$1" | tr -d ' '; }

# ─────────────────────────────────────────────────────────────────────────────
# 0. Host preconditions — cheap, and they fail in seconds rather than minutes
# ─────────────────────────────────────────────────────────────────────────────
say "Host preconditions"

OS="$(uname -s)"; ARCH="$(uname -m)"
info "host: $OS $ARCH"
if [ "$OS" != "Linux" ] || [ "$ARCH" != "x86_64" ]; then
    echo "error: this gate must run on Linux x86_64." >&2
    echo "       Tools/build-desktop.sh can CROSS-build the ELF archive from any host" >&2
    echo "       (a staticlib needs no linker), but only Linux can RUN the search," >&2
    echo "       and running the search is the entire point of this gate." >&2
    exit 2
fi

# CPU BASELINE. The archive is built +avx2,+bmi2,+popcnt and Reckless selects
# SIMD at COMPILE time with no runtime dispatch, so a runner without these dies
# with SIGILL mid-search. Checking here converts an unexplained crash into a
# one-line message, before any compile time is spent. Both self-hosted macOS
# jobs already do the sysctl equivalent.
if [ "${RECKLESS_TARGET_FEATURES:-+avx2,+bmi2,+popcnt}" = "+avx2,+bmi2,+popcnt" ]; then
    MISSING=""
    for feature in avx2 bmi2 popcnt; do
        grep -qw "$feature" /proc/cpuinfo || MISSING="$MISSING $feature"
    done
    if [ -n "$MISSING" ]; then
        echo "error: this CPU lacks required feature(s):$MISSING" >&2
        echo "       The archive is compiled for a Haswell-class baseline and does not" >&2
        echo "       runtime-dispatch; running it here would raise SIGILL, not an error." >&2
        echo "       Rebuild lower with RECKLESS_TARGET_FEATURES=+popcnt." >&2
        exit 2
    fi
    info "cpu features: avx2 bmi2 popcnt present"
else
    info "cpu features: baseline overridden (RECKLESS_TARGET_FEATURES=${RECKLESS_TARGET_FEATURES}) — check skipped"
fi

command -v swift >/dev/null 2>&1 || { echo "error: no swift on PATH" >&2; exit 2; }
command -v rustup >/dev/null 2>&1 || { echo "error: no rustup on PATH" >&2; exit 2; }
info "swift: $(swift --version 2>&1 | head -1)"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Rust pin — taken FROM rust-toolchain.toml, never floated
# ─────────────────────────────────────────────────────────────────────────────
# rust-toolchain.toml is the single source of truth. Tools/build-desktop.sh
# carries its own default for standalone use, so the two can silently drift
# apart; that drift is itself a defect worth failing on, because it means a
# developer running the script by hand and CI running it through here would be
# compiling with different compilers while both believing they are pinned.
say "Rust toolchain pin"

CHANNEL="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' rust-toolchain.toml | head -1)"
[ -n "$CHANNEL" ] || { echo "error: could not read channel from rust-toolchain.toml" >&2; exit 2; }
SCRIPT_DEFAULT="$(sed -n 's/^STABLE_TOOLCHAIN="\${RUST_STABLE_TOOLCHAIN:-\([^}]*\)}".*/\1/p' Tools/build-desktop.sh | head -1)"
info "rust-toolchain.toml channel: $CHANNEL"
info "build-desktop.sh default:    ${SCRIPT_DEFAULT:-<unreadable>}"
if [ -n "$SCRIPT_DEFAULT" ] && [ "$SCRIPT_DEFAULT" != "$CHANNEL" ]; then
    echo "error: rust-toolchain.toml pins '$CHANNEL' but Tools/build-desktop.sh defaults to" >&2
    echo "       '$SCRIPT_DEFAULT'. They must agree, or a hand-run build and a CI build use" >&2
    echo "       different compilers while both believe they are pinned. Update both." >&2
    exit 2
fi
# Pass the file's pin explicitly, so this script honours rust-toolchain.toml
# even if the script's default is ever edited.
export RUST_STABLE_TOOLCHAIN="$CHANNEL"

# ─────────────────────────────────────────────────────────────────────────────
# 2. NNUE net — verified unconditionally, cache hit or not
# ─────────────────────────────────────────────────────────────────────────────
# The checksum is re-verified on EVERY run even when the file was restored from
# a cache. A cache is an untrusted input; a corrupt or truncated net would
# otherwise present as a mysterious engine-init failure.
say "NNUE network"
mkdir -p "$NET_DIR"
if [ -f "$NET_DIR/$NET_NAME" ] && [ "$(sha256_of "$NET_DIR/$NET_NAME")" = "$NET_SHA" ]; then
    info "already staged and verified: $NET_DIR/$NET_NAME"
else
    rm -f "$NET_DIR/$NET_NAME"
    info "downloading $NET_URL"
    curl -fsSL -o "$NET_DIR/$NET_NAME.part" "$NET_URL"
    ACTUAL="$(sha256_of "$NET_DIR/$NET_NAME.part")"
    if [ "$ACTUAL" != "$NET_SHA" ]; then
        rm -f "$NET_DIR/$NET_NAME.part"
        echo "error: NNUE checksum mismatch (expected $NET_SHA, got $ACTUAL)" >&2
        exit 1
    fi
    mv "$NET_DIR/$NET_NAME.part" "$NET_DIR/$NET_NAME"
    info "downloaded and verified"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. The archive
# ─────────────────────────────────────────────────────────────────────────────
# Always invoked. A warm cargo cache makes this fast, but it is never SKIPPED on
# a cache hit — the point of the gate is the search that follows, and a cache
# must never be able to shorten the path to a green result.
say "Building the Rust archive (Tools/build-desktop.sh linux)"
# Remove any pre-existing archive FIRST, so "it exists afterwards" means this
# run produced it. Structural, not hygiene: it holds even if someone later
# re-adds rust/target to a CI cache, or runs this on a dirty local tree where a
# months-old archive is sitting in place. The gate must never qualify bytes it
# did not build.
rm -f "$ARCHIVE"
bash Tools/build-desktop.sh linux

[ -f "$ARCHIVE" ] || { echo "error: archive not produced at $ARCHIVE" >&2; exit 1; }
ARCHIVE_BYTES="$(size_of "$ARCHIVE")"
ARCHIVE_SHA="$(sha256_of "$ARCHIVE")"

say "Archive vs the 2026-08-10 proof"
info "path:     $ARCHIVE"
info "bytes:    $ARCHIVE_BYTES  (recorded $RECORDED_ARCHIVE_BYTES)"
info "sha256:   $ARCHIVE_SHA"
info "recorded: $RECORDED_ARCHIVE_SHA"

# Hard: it exists and is plausibly an engine. Advisory: it is byte-identical.
if [ "$ARCHIVE_BYTES" -lt 5000000 ]; then
    fail "archive is only $ARCHIVE_BYTES bytes; expected ~$RECORDED_ARCHIVE_BYTES"
else
    pass "archive size is plausible ($ARCHIVE_BYTES bytes)"
fi
if [ "$ARCHIVE_SHA" = "$RECORDED_ARCHIVE_SHA" ]; then
    pass "archive is byte-identical to the recorded proof"
else
    warn "archive differs from the recorded proof (advisory: a rustc patch bump or a"
    warn "      host difference changes these bytes without changing behaviour — the"
    warn "      searches below are the assertion that matters)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Build BOTH arms from this one tree
# ─────────────────────────────────────────────────────────────────────────────
# --manifest-cache none is LOAD-BEARING, not tidiness. This package's manifest
# branches on `Context.environment["SWIFTRECKLESS_LINK_ARCHIVE"]`, and SwiftPM's
# manifest cache is keyed on manifest contents and toolchain — NOT on the
# environment the manifest read. A cached manifest could therefore hand the
# second arm the first arm's build settings, which would silently collapse the
# very margin this script exists to measure. Disabling the cache costs one
# manifest compile per arm and removes the false-pass entirely.
mkdir -p "$LOG_DIR"
# Both arms are built from scratch every run. A leftover binary from an earlier
# invocation — with different env, or from before an edit — would be
# indistinguishable from this run's output, and "the gate passed" would be a
# statement about a build nobody made today. The expensive part (the engine
# compile) is what the cargo cache covers; these two Swift builds are not
# cached across CI runs anyway.
rm -rf "$STUB_SCRATCH" "$REAL_SCRATCH"

say "Arm 1 of 2 — STUB (negative control, no opt-in, no linker search path)"
# `env -u` rather than merely not setting them: if the caller's environment
# already had these exported, the negative control would quietly become a second
# real arm and the gate would assert nothing.
env -u SWIFTRECKLESS_LINK_ARCHIVE -u LIBRARY_PATH \
    swift build -c release --product reckless-known-answer \
        --scratch-path "$STUB_SCRATCH" --manifest-cache none
STUB_BIN="$(env -u SWIFTRECKLESS_LINK_ARCHIVE -u LIBRARY_PATH \
    swift build -c release --scratch-path "$STUB_SCRATCH" --manifest-cache none \
    --show-bin-path)/reckless-known-answer"
info "stub binary: $STUB_BIN"

say "Arm 2 of 2 — REAL (SWIFTRECKLESS_LINK_ARCHIVE=1, archive on LIBRARY_PATH)"
SWIFTRECKLESS_LINK_ARCHIVE=1 LIBRARY_PATH="$ARCHIVE_DIR" \
    swift build -c release --product reckless-known-answer \
        --scratch-path "$REAL_SCRATCH" --manifest-cache none
REAL_BIN="$(SWIFTRECKLESS_LINK_ARCHIVE=1 LIBRARY_PATH="$ARCHIVE_DIR" \
    swift build -c release --scratch-path "$REAL_SCRATCH" --manifest-cache none \
    --show-bin-path)/reckless-known-answer"
info "real binary: $REAL_BIN"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Run both arms
# ─────────────────────────────────────────────────────────────────────────────
say "Running the STUB arm (expected: refuses, non-zero exit)"
STUB_LOG="$LOG_DIR/stub.log"
set +e
"$STUB_BIN" > "$STUB_LOG" 2>&1
STUB_EXIT=$?
set -e
sed 's/^/    | /' "$STUB_LOG"
info "stub exit: $STUB_EXIT"

say "Running the REAL arm (expected: known answers, exit 0)"
REAL_LOG="$LOG_DIR/real.log"
set +e
"$REAL_BIN" > "$REAL_LOG" 2>&1
REAL_EXIT=$?
set -e
sed 's/^/    | /' "$REAL_LOG"
info "real exit: $REAL_EXIT"

# ─────────────────────────────────────────────────────────────────────────────
# 6. THE MARGIN
# ─────────────────────────────────────────────────────────────────────────────
say "Margin assertions (the two arms must DIFFER)"

# 6a. Behaviour.
if [ "$STUB_EXIT" -ne 0 ]; then
    pass "stub arm refused (exit $STUB_EXIT)"
else
    fail "stub arm exited 0 — the no-opt-in build must NOT play chess. Either the"
    fail "      opt-in is no longer what selects the archive, or an archive is being"
    fail "      linked unconditionally."
fi
if [ "$REAL_EXIT" -eq 0 ]; then
    pass "real arm answered every required known-answer check (exit 0)"
else
    fail "real arm exited $REAL_EXIT — see the log above; the linked archive did not"
    fail "      produce the recorded forced answers."
fi

# 6b. Self-reported backend, from the same one tree.
grep -q "backend: stub" "$STUB_LOG" \
    && pass "stub arm reported 'backend: stub'" \
    || fail "stub arm never reported 'backend: stub'"
grep -q "backend: real" "$REAL_LOG" \
    && pass "real arm reported 'backend: real'" \
    || fail "real arm never reported 'backend: real'"

# 6c. The engine's code is physically present in one binary and absent from the
#     other. Independent of anything the program chose to print, so it survives
#     a harness that lies. `grep -a` avoids depending on binutils `strings`,
#     which the Swift container does not ship.
REAL_HITS="$(grep -a -c 'Reckless 0\.9' "$REAL_BIN" || true)"
STUB_HITS="$(grep -a -c 'Reckless 0\.9' "$STUB_BIN" || true)"
info "engine version string — real binary: $REAL_HITS hit(s), stub binary: $STUB_HITS hit(s)"
[ "${REAL_HITS:-0}" -ge 1 ] \
    && pass "real binary embeds the engine version string" \
    || fail "real binary does NOT embed the engine version string — no engine was linked"
[ "${STUB_HITS:-0}" -eq 0 ] \
    && pass "stub binary embeds no engine version string" \
    || fail "stub binary DOES embed the engine version string — the negative control is not a control"

# 6d. Size. The engine is megabytes; the stubs are a handful of empty functions.
REAL_BYTES="$(size_of "$REAL_BIN")"
STUB_BYTES="$(size_of "$STUB_BIN")"
DELTA=$((REAL_BYTES - STUB_BYTES))
info "real $REAL_BYTES bytes (recorded $RECORDED_REAL_BYTES), stub $STUB_BYTES bytes (recorded $RECORDED_STUB_BYTES), delta $DELTA"
# Floor well under the recorded 5,735,360 so engine growth or a Swift runtime
# change cannot trip it, but far above any plausible noise.
[ "$DELTA" -gt 3000000 ] \
    && pass "real binary is $DELTA bytes larger than the stub (floor 3,000,000)" \
    || fail "real/stub size delta is only $DELTA bytes — the two arms look like the same build"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Verdict
# ─────────────────────────────────────────────────────────────────────────────
say "Verdict"
if [ "$FAILURES" -eq 0 ]; then
    info "Logs: $STUB_LOG, $REAL_LOG"
    printf '\n\033[1;32mPASS\033[0m — the desktop archive links AND plays chess, and the\n'
    printf '       no-opt-in build from the same tree refuses to.\n\n'
    exit 0
else
    info "Logs: $STUB_LOG, $REAL_LOG"
    printf '\n\033[1;31mFAIL\033[0m — %d margin assertion(s) failed.\n\n' "$FAILURES"
    exit 1
fi
