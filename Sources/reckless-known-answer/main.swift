// reckless-known-answer — the behavioural half of the desktop real-archive gate.
//
// WHY THIS EXISTS, GIVEN reckless-smoke AND RecklessBackendTests ALREADY DO.
//
// This package's central hazard is that Sources/CReckless/RecklessHostStubs.c
// supplies link-compatible no-op `rk_ffi_*` symbols. So a build can link
// perfectly, start, answer `uci`, and play no chess whatsoever. Three claims
// are therefore genuinely different, and only the third is worth gating on:
//
//   1. "it linked"        — every `swift build` proves this, stubs included.
//   2. "it says it's real"— RecklessBackendTests asserts the backend ENUM
//                           against SWIFTRECKLESS_EXPECT_BACKEND. An archive
//                           that links but cannot search would pass it.
//   3. "it plays chess"   — THIS harness. It asks for positions whose answer is
//                           forced, and checks the answer.
//
// reckless-smoke covers `uciok` + "some bestmove arrived" at depth 1. A canned
// reply can fake that. It cannot fake finding mate in 2, and it cannot fake a
// node count that grows monotonically with depth.
//
// This target is COMMITTED, deliberately. The margin assertions in
// Tools/verify-desktop-gate.sh and the CI job that calls it are both thin
// wrappers around this executable, so the person a red gate lands on can run
// exactly what CI ran:
//
//     bash Tools/build-desktop.sh
//     SWIFTRECKLESS_LINK_ARCHIVE=1 \
//     LIBRARY_PATH="$PWD/rust/target/x86_64-unknown-linux-gnu/release" \
//       swift run -c release reckless-known-answer
//
// A gate whose logic lives inside a YAML heredoc cannot be reproduced locally,
// and a gate nobody can reproduce gets deleted rather than fixed.
//
// SEVERITIES — two, on purpose.
//
//   [required]  Structural facts that cannot drift with an engine or Rust
//               version bump: the forced mates, the only-legal-move reply, and
//               strictly increasing node counts with depth. A failure here
//               means the build does not play chess. Exit code 1.
//
//   [canary]    Values that WERE measured on 2026-08-10 and SHOULD reproduce,
//               but whose drift is information rather than breakage: the
//               opening-move choice, its centipawn score, and the exact node
//               counts. These print WARN with the recorded value beside the
//               observed one, and do not fail the build. Asserting them hard
//               would turn every legitimate engine bump into a red gate with a
//               misleading message.
//
// NO `setoption` IS SENT. The recorded proof used engine defaults, so this
// harness uses engine defaults too; sending `Threads`/`Hash` here would make
// the observed node counts incomparable to the numbers below.
//
// Uses only Foundation + GCD (no ContinuousClock/Duration) to stay inside the
// package's macOS 10.15 floor, matching reckless-smoke.

import Foundation
import SwiftReckless

// ─────────────────────────────────────────────────────────────────────────────
// stderr routing
// ─────────────────────────────────────────────────────────────────────────────
// Write via FileHandle, not fputs(_, stderr): glibc declares the C `stderr`
// global as a mutable `var`, which Swift 6 strict concurrency rejects as shared
// mutable state on Linux. Mirrors reckless-smoke and RecklessEngine itself.

func writeErr(_ raw: String) {
    FileHandle.standardError.write(Data(raw.utf8))
}

func err(_ msg: String) {
    writeErr("[known-answer] \(msg)\n")
}

// ─────────────────────────────────────────────────────────────────────────────
// Thread-safe line buffer
// ─────────────────────────────────────────────────────────────────────────────
// @unchecked Sendable: thread safety comes from the serial DispatchQueue.

final class LineBuffer: @unchecked Sendable {
    private let q = DispatchQueue(label: "reckless-known-answer.linebuf")
    private var lines: [String] = []

    func append(_ line: String) {
        q.sync { lines.append(line) }
    }

    /// Drop everything collected so far. Called immediately before each search
    /// so a previous search's `bestmove` can never satisfy the next wait.
    func reset() {
        q.sync { lines.removeAll(keepingCapacity: true) }
    }

    func hasLine(startingWith token: String) -> Bool {
        q.sync { lines.contains(where: { $0.hasPrefix(token) }) }
    }

    func snapshot() -> [String] {
        q.sync { lines }
    }
}

func waitFor(_ token: String, in buf: LineBuffer, timeoutSeconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if buf.hasLine(startingWith: token) { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────────────
// UCI parsing
// ─────────────────────────────────────────────────────────────────────────────

struct SearchResult {
    var bestMove: String
    var depth: Int?
    var scoreKind: String?      // "cp" | "mate"
    var scoreValue: Int?
    var nodes: Int?
    var nps: Int?
    var pv: [String]

    var scoreText: String {
        guard let kind = scoreKind, let value = scoreValue else { return "score <none>" }
        return "score \(kind) \(value)"
    }
}

/// Parse one completed search out of the lines collected since the last reset.
///
/// Takes the LAST `info` line that carries both a `score` and a `pv` — info
/// lines without a pv are `currmove` progress reports, and a trailing
/// lowerbound/upperbound line would misreport the final evaluation.
func parseSearch(_ lines: [String]) -> SearchResult? {
    var best: String?
    var chosen: [String]?

    for line in lines {
        if line.hasPrefix("bestmove") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 { best = String(parts[1]) }
            continue
        }
        guard line.hasPrefix("info ") else { continue }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard tokens.contains("score"), tokens.contains("pv") else { continue }
        chosen = tokens
    }

    guard let bestMove = best else { return nil }

    var result = SearchResult(
        bestMove: bestMove, depth: nil, scoreKind: nil, scoreValue: nil,
        nodes: nil, nps: nil, pv: []
    )

    guard let tokens = chosen else { return result }

    func intAfter(_ key: String) -> Int? {
        guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count else { return nil }
        return Int(tokens[i + 1])
    }

    result.depth = intAfter("depth")
    result.nodes = intAfter("nodes")
    result.nps = intAfter("nps")

    if let s = tokens.firstIndex(of: "score"), s + 2 < tokens.count {
        result.scoreKind = tokens[s + 1]
        result.scoreValue = Int(tokens[s + 2])
    }
    if let p = tokens.firstIndex(of: "pv"), p + 1 < tokens.count {
        result.pv = Array(tokens[(p + 1)...])
    }
    return result
}

// ─────────────────────────────────────────────────────────────────────────────
// Verdict ledger
// ─────────────────────────────────────────────────────────────────────────────
// Deliberately NOT Sendable and never captured by the output task: top-level
// code is @MainActor-isolated, and every mutation below happens there.

final class Ledger {
    private(set) var failures: [String] = []
    private(set) var warnings: [String] = []

    func require(_ ok: Bool, _ label: String, _ detail: String) {
        if ok {
            err("    PASS  [required]  \(label): \(detail)")
        } else {
            err("    FAIL  [required]  \(label): \(detail)")
            failures.append("\(label) — \(detail)")
        }
    }

    func canary(_ ok: Bool, _ label: String, _ detail: String) {
        if ok {
            err("    ok    [canary]    \(label): \(detail)")
        } else {
            err("    WARN  [canary]    \(label): \(detail)")
            warnings.append("\(label) — \(detail)")
        }
    }
}

let ledger = Ledger()

// ─────────────────────────────────────────────────────────────────────────────
// 1. NEGATIVE CONTROL — refuse the stub backend before touching the filesystem
// ─────────────────────────────────────────────────────────────────────────────
// This is the half of the gate that runs on the arm with NO archive, and it is
// why the gate can tell you the opt-in did something. Exiting here — non-zero,
// with "backend: stub" on stderr — is the EXPECTED and REQUIRED outcome of the
// stub arm. Tools/verify-desktop-gate.sh asserts exactly that, and asserts the
// real arm reaches the end of this file instead.
//
// No net is needed to reach this point, which is what makes the negative
// control the cheap half of the margin.

err("backend: \(RecklessBackend.current)")
guard RecklessBackend.current == .real else {
    err("FAIL — this build links the no-op stub backend; there is no engine to question.")
    err("       Linux/Windows: build the archive (Tools/build-desktop.sh), put its")
    err("       directory on the linker search path, and set SWIFTRECKLESS_LINK_ARCHIVE=1.")
    exit(1)
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Locate the NNUE net
// ─────────────────────────────────────────────────────────────────────────────
// Defaults to the gitignored dev location the rest of the repo already uses
// (rust/networks/). RECKLESS_NET_DIR overrides it so a CI job can stage the net
// on a cached path outside the checkout without editing this file.

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/reckless-known-answer
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // package root

let netDir: URL = {
    if let override = ProcessInfo.processInfo.environment["RECKLESS_NET_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    return packageRoot
        .appendingPathComponent("rust", isDirectory: true)
        .appendingPathComponent("networks", isDirectory: true)
}()

let netFile = netDir.appendingPathComponent(RecklessNetworkLoader.network.filename)
err("net directory: \(netDir.path)")
guard FileManager.default.fileExists(atPath: netFile.path) else {
    err("FAIL — NNUE net not found at \(netFile.path)")
    err("       Stage \(RecklessNetworkLoader.network.filename) there, or set RECKLESS_NET_DIR.")
    exit(1)
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Start the engine and collect its output
// ─────────────────────────────────────────────────────────────────────────────

guard let engine = RecklessEngine(networkDirectory: netDir) else {
    err("FAIL — RecklessEngine init returned nil (FFI failure or net unreadable)")
    exit(1)
}

let buf = LineBuffer()
let collectSema = DispatchSemaphore(value: 0)
let verbose = ProcessInfo.processInfo.environment["RECKLESS_KNOWN_ANSWER_VERBOSE"] == "1"

// One cancellation-safe consumer for the engine's whole lifetime, as
// RecklessEngine's documentation requires.
let collectTask = Task.detached {
    for await line in engine.cancellationSafeOutput {
        buf.append(line)
        if verbose { writeErr("[engine] \(line)\n") }
    }
    collectSema.signal()
}

func bail(_ message: String) -> Never {
    err("FAIL — \(message)")
    err("       Lines seen: \(buf.snapshot().suffix(20))")
    engine.shutdown()
    _ = collectSema.wait(timeout: .now() + 5)
    collectTask.cancel()
    exit(1)
}

// ── UCI handshake ────────────────────────────────────────────────────────────
buf.reset()
engine.uci()
guard waitFor("uciok", in: buf, timeoutSeconds: 20) else {
    bail("timed out waiting for uciok (20 s)")
}

let idName = buf.snapshot()
    .first(where: { $0.hasPrefix("id name") })
    .map { String($0.dropFirst("id name".count)).trimmingCharacters(in: .whitespaces) }
    ?? "<no id name>"
err("engine id name: \(idName)")

err("")
err("── Identity ──────────────────────────────────────────────────────────────")
// A stub cannot produce this, and neither can a build that linked the wrong
// archive. Cheap, and it names the engine in the log for free.
ledger.require(
    idName.lowercased().contains("reckless"),
    "engine identifies as Reckless",
    "id name = \"\(idName)\""
)

// ─────────────────────────────────────────────────────────────────────────────
// 4. Search driver
// ─────────────────────────────────────────────────────────────────────────────
// `ucinewgame` + `isready` before every search so each result is measured from
// a clean transposition table and is therefore reproducible in isolation. The
// buffer is reset twice — once so a stale `readyok` cannot satisfy the wait,
// once so a stale `bestmove` cannot.

func search(fen: String, depth: Int, timeoutSeconds: Double = 120) -> SearchResult {
    buf.reset()
    engine.newGame()
    engine.isReady()
    guard waitFor("readyok", in: buf, timeoutSeconds: 30) else {
        bail("timed out waiting for readyok before \(fen) depth \(depth)")
    }

    buf.reset()
    engine.setPosition(fen: fen)
    engine.go(depth: depth)
    guard waitFor("bestmove", in: buf, timeoutSeconds: timeoutSeconds) else {
        bail("timed out waiting for bestmove: \(fen) depth \(depth) (\(timeoutSeconds) s)")
    }
    guard let result = parseSearch(buf.snapshot()) else {
        bail("could not parse a search result for \(fen) depth \(depth)")
    }
    return result
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Forced-answer positions
// ─────────────────────────────────────────────────────────────────────────────
// FENs and expectations are transcribed verbatim from the proof run recorded on
// 2026-08-10 (Ubuntu 24.04 x86_64, Swift 6.3.3, SwiftReckless 703f92a, Rust
// 1.96.1, fork tag swiftreckless-v0.9.1 = de35beac). Reuse of the exact FENs is
// the point: a regression here is directly comparable to that transcript.
//
// These are [required]. Every one has a single correct answer that follows from
// the rules of chess, not from engine taste, so no engine version can move them.

struct ForcedCase {
    let name: String
    let fen: String
    let depth: Int
    let expectedBestMove: String
    /// Exact mate distance if the position is a forced mate, else nil.
    let expectedMateIn: Int?
    let recorded: String
}

let forcedCases: [ForcedCase] = [
    ForcedCase(
        name: "back-rank mate",
        fen: "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1",
        depth: 8,
        expectedBestMove: "a1a8",
        expectedMateIn: 1,
        recorded: "a1a8, score mate 1"
    ),
    ForcedCase(
        name: "Win At Chess #001",
        fen: "2rr3k/pp3pp1/1nnqbN1p/3pN3/2pP4/2P3Q1/PPB4P/R4RK1 w - - 0 1",
        depth: 10,
        expectedBestMove: "g3g6",
        expectedMateIn: 2,
        recorded: "g3g6, score mate 2"
    ),
    ForcedCase(
        name: "only legal move",
        fen: "4k3/8/8/8/8/8/4q3/4K2R w K - 0 1",
        depth: 6,
        expectedBestMove: "e1e2",
        expectedMateIn: nil,
        recorded: "e1e2"
    ),
]

for c in forcedCases {
    err("")
    err("── \(c.name) ─────────────────────────────────────────────────────────")
    err("    fen:      \(c.fen)")
    err("    recorded: \(c.recorded)")
    let r = search(fen: c.fen, depth: c.depth)
    err("    observed: \(r.bestMove), \(r.scoreText), nodes \(r.nodes.map(String.init) ?? "?")")

    ledger.require(
        r.bestMove == c.expectedBestMove,
        "\(c.name) bestmove",
        "expected \(c.expectedBestMove), got \(r.bestMove)"
    )

    if let mateIn = c.expectedMateIn {
        // A canned reply can echo a move. It cannot report the correct distance
        // to a mate it did not search for — which is why the mates carry the
        // weight here and the depth-1 smoke test does not.
        ledger.require(
            r.scoreKind == "mate" && r.scoreValue == mateIn,
            "\(c.name) score",
            "expected mate \(mateIn), got \(r.scoreText)"
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Node growth with depth
// ─────────────────────────────────────────────────────────────────────────────
// The second thing a canned reply cannot fake. A search tree must get strictly
// bigger as the depth limit rises; a table lookup reports the same number, zero,
// or nothing at all.
//
// METHODOLOGY NOTE — READ BEFORE COMPARING NUMBERS TO THE PROOF TRANSCRIPT.
// `search()` sends `ucinewgame` first, so every depth below is measured from an
// EMPTY transposition table. The 2026-08-10 transcript recorded
//     3,607 @6    30,888 @10    191,293 @14    330,417 @16
// but only the depth-16 figure is directly comparable: re-running this harness
// reproduces 330,417 exactly, while 6/10/14 come out materially different
// (787 / 21,673 / 205,258 on a fresh table), which is the signature of the
// three shallower figures having been recorded under TT CARRY-OVER inside one
// session.
// So the three shallow figures are kept as CONTEXT ONLY and are not asserted
// against; depth 16 is the one node count with a trustworthy baseline.
//
// Fresh tables are the right methodology for a gate regardless: each depth is
// then reproducible in isolation, which is exactly what makes "strictly
// increasing" a statement about the search rather than about ordering effects.

let growthDepths = [6, 10, 14, 16]
/// Directly comparable, fresh-table baseline. Depth 16 only — see the note above.
let comparableNodes: [Int: Int] = [16: 330_417]
/// Context only: the transcript's shallow figures, recorded with TT carry-over.
let transcriptCarryOverNodes: [Int: Int] = [6: 3_607, 10: 30_888, 14: 191_293]

err("")
err("── startpos node growth (fresh table before every depth) ─────────────────")
var observed: [(depth: Int, result: SearchResult)] = []
for d in growthDepths {
    let r = search(fen: "startpos", depth: d)
    observed.append((d, r))
    let note: String
    if let baseline = comparableNodes[d] {
        note = "baseline \(baseline)"
    } else if let carry = transcriptCarryOverNodes[d] {
        note = "transcript \(carry), TT carry-over — context only"
    } else {
        note = "no baseline"
    }
    err("    depth \(d): nodes \(r.nodes.map(String.init) ?? "?") (\(note)), "
        + "\(r.scoreText), best \(r.bestMove), pv \(r.pv.count) plies")
}

// [required] — every search must report a node count at all …
for (d, r) in observed {
    ledger.require(
        (r.nodes ?? 0) > 0,
        "startpos depth \(d) reports nodes",
        "nodes = \(r.nodes.map(String.init) ?? "<absent>")"
    )
}

// … and the counts must strictly increase with depth.
for i in 1..<observed.count {
    let prev = observed[i - 1]
    let cur = observed[i]
    ledger.require(
        (cur.result.nodes ?? 0) > (prev.result.nodes ?? 0),
        "node growth depth \(prev.depth) → \(cur.depth)",
        "\(prev.result.nodes ?? 0) → \(cur.result.nodes ?? 0) (must strictly increase)"
    )
}

// [required] — a floor that no stub or lookup table reaches, chosen an order of
// magnitude under the recorded 191,293 so engine tuning cannot trip it.
if let d14 = observed.first(where: { $0.depth == 14 })?.result.nodes {
    ledger.require(
        d14 >= 20_000,
        "depth 14 searched a real tree",
        "\(d14) nodes (floor 20,000; recorded 191,293)"
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. Opening canaries — reported, never fatal
// ─────────────────────────────────────────────────────────────────────────────

err("")
err("── opening canaries (advisory) ───────────────────────────────────────────")
if let d16 = observed.first(where: { $0.depth == 16 })?.result {
    ledger.canary(
        d16.bestMove == "e2e4",
        "startpos depth 16 bestmove",
        "recorded e2e4, got \(d16.bestMove)"
    )
    if d16.scoreKind == "cp", let cp = d16.scoreValue {
        ledger.canary(
            abs(cp - 40) <= 40,
            "startpos depth 16 score",
            "recorded cp 40, got cp \(cp) (advisory band ±40)"
        )
    } else {
        ledger.canary(false, "startpos depth 16 score", "recorded cp 40, got \(d16.scoreText)")
    }
    ledger.canary(
        d16.pv.count >= 12,
        "startpos depth 16 PV length",
        "recorded 24 plies, got \(d16.pv.count)"
    )
    if let n = d16.nodes {
        let drift = Double(n - 330_417) / 330_417.0 * 100.0
        ledger.canary(
            abs(drift) <= 50.0,
            "startpos depth 16 node count",
            String(format: "recorded 330,417, got %d (%+.1f%%)", n, drift)
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. Shutdown and verdict
// ─────────────────────────────────────────────────────────────────────────────

engine.shutdown()
_ = collectSema.wait(timeout: .now() + 5)
collectTask.cancel()

err("")
err("══ verdict ═══════════════════════════════════════════════════════════════")
if !ledger.warnings.isEmpty {
    err("\(ledger.warnings.count) canary drift(s) — informational, not fatal:")
    for w in ledger.warnings { err("    WARN  \(w)") }
}
if ledger.failures.isEmpty {
    err("PASS — the linked build plays chess: forced mates found, only-legal-move")
    err("       played, node counts strictly increasing with depth.")
    exit(0)
} else {
    err("\(ledger.failures.count) required check(s) FAILED:")
    for f in ledger.failures { err("    FAIL  \(f)") }
    err("FAIL — the linked build does not play chess correctly.")
    exit(1)
}
