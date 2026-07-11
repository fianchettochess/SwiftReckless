import Testing
import Foundation
@testable import SwiftReckless

// ─────────────────────────────────────────────────────────────────────────────
// Suite 1 — Offline / pure-logic (always run, no engine, no net)
// ─────────────────────────────────────────────────────────────────────────────

@Suite("RecklessNetworkLoader offline tests")
struct NetworkLoaderTests {

    @Test("Network spec is the pinned v54 net")
    func networkSpec() {
        let net = RecklessNetworkLoader.network
        #expect(net.filename == "v54-5478683c.nnue")
        #expect(net.shaPrefix == "5478683c")
        #expect(net.sha256 == "5478683cb1bababde29ae8f29468a99846726548fc6a0ed54cac40ab6d38efbf")
        #expect(net.downloadURL.scheme == "https")
    }

    @Test("Filename encodes the SHA-256 prefix")
    func filenameEncodesSHA() {
        let net = RecklessNetworkLoader.network
        let parts = net.filename.replacingOccurrences(of: ".nnue", with: "").split(separator: "-")
        #expect(parts.count == 2)
        #expect(String(parts[1]) == net.shaPrefix)
        #expect(net.sha256.hasPrefix(net.shaPrefix))
    }

    @Test("Engine init returns nil when the net is absent")
    func initNilWithoutNet() {
        // A directory that cannot contain the net → init? must fail gracefully.
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("reckless-empty-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(RecklessEngine(networkDirectory: empty) == nil)
    }

    @Test("Verification compares the complete SHA-256, not only the filename prefix")
    func fullSHA256Verification() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reckless-hash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("fixture.nnue")
        try Data("swiftreckless-full-digest".utf8).write(to: file)
        let digest = "5479707c3cd8b9efb81e5ecc2285cc26e1d9d20b0dbcf5a20ddcad07f8be6f29"
        let samePrefixWrongDigest = "5479707c" + String(repeating: "0", count: 56)

        #expect(RecklessNetworkLoader.fileMatchesSHA256(file, expectedSHA256: digest))
        #expect(!RecklessNetworkLoader.fileMatchesSHA256(file, expectedSHA256: samePrefixWrongDigest))
        #expect(!RecklessNetworkLoader.fileMatchesSHA256(file, expectedSHA256: "5479707c"))
    }
}

@Suite("Reckless output cancellation")
struct RecklessOutputTests {
    @Test("pre-subscription lines remain buffered")
    func preSubscriptionBuffering() async {
        let storage = RecklessOutputStorage()
        let output = RecklessOutput(storage: storage)
        storage.yield("prebuffered")
        let iterator = output.makeAsyncIterator()
        #expect(await iterator.next() == "prebuffered")
    }

    @Test("cancelling one waiter does not terminate a successor")
    func cancellationIsPerWaiter() async {
        let storage = RecklessOutputStorage()
        let output = RecklessOutput(storage: storage)
        let cancelled = Task {
            let iterator = output.makeAsyncIterator()
            return await iterator.next()
        }
        while storage.waitingConsumerCount == 0 { await Task.yield() }
        cancelled.cancel()
        #expect(await cancelled.value == nil)

        storage.yield("after-cancel")
        let successor = output.makeAsyncIterator()
        #expect(await successor.next() == "after-cancel")
    }

    @Test("breaking an iterator leaves the channel reusable")
    func naturalBreakIsReusable() async {
        let storage = RecklessOutputStorage()
        let output = RecklessOutput(storage: storage)
        storage.yield("first")
        for await line in output {
            #expect(line == "first")
            break
        }
        storage.yield("second")
        let successor = output.makeAsyncIterator()
        #expect(await successor.next() == "second")
    }

    @Test("finish drains buffered lines before EOF")
    func finishDrainsBuffer() async {
        let storage = RecklessOutputStorage()
        let output = RecklessOutput(storage: storage)
        storage.yield("last")
        storage.finish()
        let iterator = output.makeAsyncIterator()
        #expect(await iterator.next() == "last")
        #expect(await iterator.next() == nil)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite 2 — Engine smoke (net-guarded; runs by default when the net is staged)
// ─────────────────────────────────────────────────────────────────────────────
// One test, one engine instance (the engine uses a process-wide output sink, so
// concurrent engines would collide). Guarded on the gitignored dev net.

@Suite("RecklessEngine smoke")
struct RecklessEngineSmokeTests {

    /// The gitignored dev net at <package>/rust/networks/, if present.
    private static var stagedNetDir: URL? {
        let dir = URL(fileURLWithPath: #filePath)   // .../Tests/SwiftRecklessTests/ThisFile.swift
            .deletingLastPathComponent()            // SwiftRecklessTests
            .deletingLastPathComponent()            // Tests
            .deletingLastPathComponent()            // package root
            .appendingPathComponent("rust/networks", isDirectory: true)
        let net = dir.appendingPathComponent(RecklessNetworkLoader.network.filename)
        return FileManager.default.fileExists(atPath: net.path) ? dir : nil
    }

    /// Race the output stream against a timeout; true if a matching line arrives.
    private func awaitLine(_ engine: RecklessEngine, timeout: Duration,
                           where pred: @escaping @Sendable (String) -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await line in engine.cancellationSafeOutput where pred(line) { return true }
                return false
            }
            group.addTask { (try? await Task.sleep(for: timeout)) != nil ? false : false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    @Test("uci → uciok, isready → readyok, go → bestmove, end-to-end")
    func fullHandshake() async throws {
        #if os(macOS)
        // The forced-source macOS arm intentionally links host no-op stubs;
        // only Android links the source-built Rust archive. A developer may
        // still have the ignored net staged locally, which must not turn this
        // host-introspection configuration into a false integration failure.
        if ProcessInfo.processInfo.environment["SWIFTRECKLESS_FORCE_SOURCE_BUILD"] == "1" {
            return
        }
        #endif
        guard let netDir = Self.stagedNetDir else {
            // Net is gitignored; a fresh checkout / CI without it skips (passes).
            return
        }
        guard let engine = RecklessEngine(networkDirectory: netDir) else {
            Issue.record("RecklessEngine(networkDirectory:) returned nil — net present but engine failed to start")
            return
        }
        defer { engine.shutdown() }

        engine.uci()
        #expect(await awaitLine(engine, timeout: .seconds(10)) { $0 == "uciok" }, "no uciok")

        engine.isReady()
        #expect(await awaitLine(engine, timeout: .seconds(5)) { $0 == "readyok" }, "no readyok")

        // Cancel an idle waiter, then prove a fresh iterator still receives
        // output from the same process-lifetime engine.
        let cancelledWaiter = Task {
            let iterator = engine.cancellationSafeOutput.makeAsyncIterator()
            return await iterator.next()
        }
        try? await Task.sleep(for: .milliseconds(25))
        cancelledWaiter.cancel()
        #expect(await cancelledWaiter.value == nil)
        engine.isReady()
        #expect(await awaitLine(engine, timeout: .seconds(5)) { $0 == "readyok" },
                "output did not survive iterator cancellation")

        engine.send("go depth 1")
        #expect(await awaitLine(engine, timeout: .seconds(30)) { $0.hasPrefix("bestmove") }, "no bestmove")

        // The injected-channel engine must remain command-responsive while
        // its synchronous search loop is running. The ready barrier is
        // deliberately awaited after bestmove: if readyok overtakes the old
        // terminal result, the first matcher consumes it and the second wait
        // fails, exposing stale-output handoff risk in app consumers.
        engine.send("go infinite")
        #expect(await awaitLine(engine, timeout: .seconds(5)) { $0.hasPrefix("info ") },
                "infinite search did not start")
        engine.send("stop")
        engine.isReady()
        #expect(await awaitLine(engine, timeout: .seconds(2)) { $0.hasPrefix("bestmove") },
                "stop did not terminate the active search promptly")
        #expect(await awaitLine(engine, timeout: .seconds(2)) { $0 == "readyok" },
                "post-stop readyok did not follow the old bestmove")

        engine.shutdown()
        engine.shutdown() // idempotent
        engine.send("isready") // safe no-op after teardown
    }
}
