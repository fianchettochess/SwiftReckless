// reckless-smoke — end-to-end host smoke test for RecklessEngine.
//
// All status output goes to STDERR via `writeErr` (below) — keeping stdout clean
// for the engine and avoiding fputs(_, stderr), whose C `stderr` global is not
// concurrency-safe on Linux under Swift 6.
//
// The smoke test:
//   1. Copies the dev net (rust/networks/v54-5478683c.nnue) into a temp dir.
//   2. Creates RecklessEngine(networkDirectory: tmpDir).
//   3. Collects output lines with a DispatchQueue-protected buffer.
//   4. Sends "uci" — waits up to 10 s for "uciok".
//   5. Sends "go depth 1" — waits up to 30 s for "bestmove".
//   6. Prints PASS/FAIL to stderr; exits 0 on pass, 1 on fail.
//
// Uses only Foundation + GCD — no ContinuousClock/Duration (macOS 13+).
// Compatible with the package's macOS 10.15 floor.

import Foundation
import SwiftReckless

// ── stderr helper ─────────────────────────────────────────────────────────────
// Write via FileHandle, not fputs(_, stderr): glibc's stdio.h declares the C
// `stderr` global as a mutable `var`, which Swift 6 strict concurrency rejects as
// shared mutable state on Linux (Apple's SDK happens to permit it). FileHandle is
// portable + concurrency-clean — mirrors RecklessEngine's own stderr routing.
func writeErr(_ raw: String) {
    FileHandle.standardError.write(Data(raw.utf8))
}
func err(_ msg: String) {
    writeErr("[reckless-smoke] \(msg)\n")
}

// ── Thread-safe line buffer using a serial DispatchQueue ──────────────────────
// @unchecked Sendable: thread safety is provided by the serial DispatchQueue.
final class LineBuffer: @unchecked Sendable {
    private let q = DispatchQueue(label: "reckless-smoke.linebuf")
    private var lines: [String] = []

    func append(_ line: String) {
        q.sync { lines.append(line) }
    }

    func hasLine(startingWith token: String) -> Bool {
        q.sync { lines.contains(where: { $0.hasPrefix(token) }) }
    }

    func dump() -> [String] {
        q.sync { lines }
    }
}

// ── Polling wait using Date (macOS 10.15+) ────────────────────────────────────
func waitFor(
    _ token: String,
    in buf: LineBuffer,
    timeoutSeconds: Double
) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if buf.hasLine(startingWith: token) { return true }
        Thread.sleep(forTimeInterval: 0.05) // 50 ms poll interval
    }
    return false
}

// ── Report the linked backend, and refuse to "pass" on stubs ─────────────────
// The stub backend links cleanly and does nothing; a smoke test that reported a
// generic init failure there would leave the reader guessing whether the net or
// the build was at fault. Name it, and fail before touching the filesystem.
err("backend: \(RecklessBackend.current)")
guard RecklessBackend.current == .real else {
    err("FAIL — this build links the no-op stub backend; there is no engine to smoke.")
    err("       Linux/Windows: build the archive (Tools/build-desktop.sh), put its")
    err("       directory on the linker search path, and set SWIFTRECKLESS_LINK_ARCHIVE=1.")
    exit(1)
}

// ── Locate the pre-placed dev net ─────────────────────────────────────────────
let sourceFileDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Sources/reckless-smoke
    .deletingLastPathComponent()   // Sources
    .deletingLastPathComponent()   // package root

let devNetPath = sourceFileDir
    .appendingPathComponent("rust")
    .appendingPathComponent("networks")
    .appendingPathComponent(RecklessNetworkLoader.network.filename)

err("dev net path: \(devNetPath.path)")
guard FileManager.default.fileExists(atPath: devNetPath.path) else {
    err("FAIL — dev net not found at \(devNetPath.path)")
    exit(1)
}

// ── Stage net into a temp directory ──────────────────────────────────────────
let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("reckless-smoke-\(UUID().uuidString)")

do {
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let dest = tmpDir.appendingPathComponent(RecklessNetworkLoader.network.filename)
    try FileManager.default.copyItem(at: devNetPath, to: dest)
    err("net staged to \(dest.path)")
} catch {
    err("FAIL — could not stage net: \(error)")
    exit(1)
}
defer { try? FileManager.default.removeItem(at: tmpDir) }

// ── Create engine ─────────────────────────────────────────────────────────────
err("creating RecklessEngine(networkDirectory: \(tmpDir.path))")
guard let engine = RecklessEngine(networkDirectory: tmpDir) else {
    err("FAIL — RecklessEngine init returned nil (FFI failure or net unreadable)")
    exit(1)
}
err("engine created")

// ── Collect output lines on a background thread ───────────────────────────────
let buf = LineBuffer()
let collectSema = DispatchSemaphore(value: 0)

// Keep one cancellation-safe consumer for the engine's full lifetime.
// Drive the async world from a detached Task inside a RunLoop.
let collectTask = Task.detached {
    for await line in engine.cancellationSafeOutput {
        buf.append(line)
        writeErr("[engine] \(line)\n")
    }
    collectSema.signal()
}

// ── Step 1: uci → uciok ──────────────────────────────────────────────────────
err("sending 'uci'")
engine.uci()

if waitFor("uciok", in: buf, timeoutSeconds: 10) {
    err("PASS — received uciok")
} else {
    err("FAIL — timed out waiting for uciok (10 s)")
    err("       Lines received: \(buf.dump())")
    engine.quit()
    exit(1)
}

// ── Step 2 (bonus): go depth 1 → bestmove ────────────────────────────────────
err("sending 'go depth 1'")
engine.send("go depth 1")

if waitFor("bestmove", in: buf, timeoutSeconds: 30) {
    err("PASS — received bestmove")
} else {
    err("FAIL — timed out waiting for bestmove (30 s)")
    err("       Lines received: \(buf.dump())")
    engine.quit()
    exit(1)
}

// ── Shutdown ──────────────────────────────────────────────────────────────────
err("shutting down")
// shutdown() sends quit, JOINS the engine thread, and finishes the output
// stream (so the collect task ends cleanly rather than via the timeout below).
engine.shutdown()
_ = collectSema.wait(timeout: .now() + 5)
collectTask.cancel()

err("=== PASS: uciok + bestmove received end-to-end ===")
exit(0)
