import Testing
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SwiftReckless
// Imported directly so the backend test can compare the Swift report against
// the C bridge's own answer rather than against itself.
import CReckless

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

    // ensure() stages downloads at a hidden `.<net>.<UUID>.part` in the net
    // directory; in-process cleanup is only the `defer` in ensure(), so a
    // crash/kill during the verify/install window (hashing the ~20-45 MB net)
    // orphans the file forever unless a pruning sweep reclaims it. The sweep
    // mirrors SwiftStockfish's pruneStaleNetworks (see the intentional-mirror
    // note in both loaders). Hermetic: the injected synthetic net is
    // present+valid (its full SHA-256 matches the fixture bytes), so ensure()
    // never reaches its download path.
    @Test("ensure prunes orphaned .part staging files and stale nets, keeps the valid net and bystanders")
    func prunesOrphanedStagingAndStaleNets() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reckless-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default

        // A synthetic net whose pinned SHA-256 really matches the fixture.
        let content = Data("swiftreckless-synthetic-net".utf8)
        let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let net = RecklessNetworkLoader.Network(
            filename: "v54-\(String(sha.prefix(8))).nnue",
            sha256: sha,
            downloadURL: URL(string: "https://invalid.example/never-fetched")!
        )
        let validURL = dir.appendingPathComponent(net.filename)
        try content.write(to: validURL)

        // Orphaned staging files, named exactly as ensure() stages them —
        // one for the current net, one from a previous version's crashed run.
        let orphanCurrent = dir.appendingPathComponent(
            ".\(net.filename).\(UUID().uuidString).part"
        )
        let orphanOld = dir.appendingPathComponent(
            ".v53-deadbeef.nnue.\(UUID().uuidString).part"
        )
        try Data("half-downloaded".utf8).write(to: orphanCurrent)
        try Data("half-downloaded".utf8).write(to: orphanOld)

        // A stale net from a previous Reckless version, and bystanders the
        // sweep must never touch.
        let staleNet = dir.appendingPathComponent("v53-deadbeef.nnue")
        let hiddenBystander = dir.appendingPathComponent(".unrelated-hidden")
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("stale".utf8).write(to: staleNet)
        try Data("keep me".utf8).write(to: hiddenBystander)
        try Data("keep me too".utf8).write(to: notes)

        let installed = try await RecklessNetworkLoader(network: net).ensure(in: dir)

        #expect(installed == validURL)
        #expect(fm.fileExists(atPath: validURL.path), "the valid net must be kept")
        #expect(!fm.fileExists(atPath: orphanCurrent.path),
                "orphaned .part staging file for the current net must be pruned")
        #expect(!fm.fileExists(atPath: orphanOld.path),
                "orphaned .part staging file from a previous version must be pruned")
        #expect(!fm.fileExists(atPath: staleNet.path),
                "a stale previous-version net must be pruned")
        #expect(fm.fileExists(atPath: hiddenBystander.path),
                "unrelated hidden files must be untouched")
        #expect(fm.fileExists(atPath: notes.path), "non-net files must be untouched")
        #expect(try Data(contentsOf: validURL) == content, "the kept net's bytes are undisturbed")
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

    // RecklessEngine.output used to be a computed property that built a fresh
    // AsyncStream + forwarding Task per access — each access spawned a
    // competing FIFO consumer that silently stole lines. The cached box must
    // hold ONE forwarding consumer no matter how often the property is read.
    // (Tested at the box level: the property itself lives on RecklessEngine,
    // which cannot be constructed without the gitignored net + Rust engine.)
    @Test("repeated output access spawns exactly one FIFO consumer and steals no lines")
    func forwardedOutputIsSingleInstance() async {
        let storage = RecklessOutputStorage()
        let forwarded = RecklessForwardedOutput(storage: storage)

        let first = forwarded.stream
        _ = forwarded.stream   // a second access must NOT add a second consumer
        _ = forwarded.stream   // nor a third

        // Wait until the forwarding consumer is parked on the FIFO, then give
        // any would-be extra consumers ample chance to park too.
        while storage.waitingConsumerCount < 1 { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
        #expect(storage.waitingConsumerCount == 1,
                "repeated .output access must not spawn competing FIFO consumers")

        // With a single consumer, every line reaches the one stream in order —
        // nothing is stolen by a discarded stream's forwarder. Bounded by a
        // timeout race: pre-fix, stolen lines would leave this read suspended
        // forever (a hang, not a failure), so the timer converts a regression
        // into a clean red.
        storage.yield("one")
        storage.yield("two")
        let received = await withTaskGroup(of: [String].self) { group in
            group.addTask {
                var lines: [String] = []
                var iterator = first.makeAsyncIterator()
                while lines.count < 2, let line = await iterator.next() {
                    lines.append(line)
                }
                return lines
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return []  // timed out — lines were stolen by a competing consumer
            }
            let winner = await group.next() ?? []
            group.cancelAll()
            return winner
        }
        #expect(received == ["one", "two"],
                "every line must reach the single shared stream, in order")

        storage.finish()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite 1b — Backend reporting (always runs, no engine, no net)
// ─────────────────────────────────────────────────────────────────────────────
// The stub backend is a supported configuration; an UNDETECTED stub backend is
// the bug this package refuses to ship. These tests hold the reporting honest.

@Suite("Reckless backend reporting")
struct RecklessBackendTests {

    @Test("current mirrors the C bridge's compile-time report")
    func currentMirrorsBridge() {
        #expect((RecklessBackend.current == .stub) == (rk_backend_is_stub() != 0))
        #expect(RecklessBackend.isEngineAvailable == (RecklessBackend.current == .real))
    }

    // A recorded skip on a real link, never a silent pass (the trait, not a
    // `#require` guard: a guard would fail the run on every real build).
    @Test(
        "a stub build cannot start an engine, whatever the net directory holds",
        .enabled(if: RecklessBackend.current == .stub, "only meaningful on a stub link")
    )
    func stubBuildNeverStarts() throws {
        // Point at the real staged dev net if the developer has one: on a stub
        // build even a perfectly provisioned directory must still fail, which
        // is exactly why the failure needs a name of its own.
        let netDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rust/networks", isDirectory: true)
        #expect(RecklessEngine(networkDirectory: netDir) == nil)
    }

    // CI's contract test. A build pipeline knows which backend it MEANT to
    // produce; without this, "Linux built green" is equally consistent with
    // "linked the real archive" and "silently linked stubs" — and the second
    // is the failure this whole design targets. Set
    // SWIFTRECKLESS_EXPECT_BACKEND=real|stub in any job that has an opinion.
    @Test(
        "linked backend matches SWIFTRECKLESS_EXPECT_BACKEND",
        .enabled(
            if: ProcessInfo.processInfo.environment["SWIFTRECKLESS_EXPECT_BACKEND"] != nil,
            "set SWIFTRECKLESS_EXPECT_BACKEND=real|stub to assert the link"
        )
    )
    func matchesDeclaredExpectation() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["SWIFTRECKLESS_EXPECT_BACKEND"])
        let expected = try #require(
            RecklessBackend(rawValue: raw),
            "SWIFTRECKLESS_EXPECT_BACKEND must be exactly 'real' or 'stub', got '\(raw)'"
        )
        #expect(RecklessBackend.current == expected,
                "build linked the \(RecklessBackend.current) backend but the job declared \(expected)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite 2 — Engine smoke (net-guarded; runs by default when the net is staged)
// ─────────────────────────────────────────────────────────────────────────────
// Serialized: at most one engine may be live at a time (overlap is rejected at
// the FFI gate), so the engine tests must never run concurrently. Guarded on
// the gitignored dev net.

@Suite("RecklessEngine smoke", .serialized)
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

    /// True when this build intentionally links the host no-op stubs. A
    /// developer may still have the ignored net staged locally, which must not
    /// turn a stub configuration into a false integration failure.
    ///
    /// This used to be inferred from `os(macOS) && SWIFTRECKLESS_FORCE_SOURCE_BUILD`
    /// — a guess about the build, made from the environment. It is now the
    /// build's own report (`rk_backend_is_stub()`), which is exact on every
    /// platform and stays correct for the desktop arm, where the same env var
    /// can mean either backend depending on whether an archive was supplied.
    private static var isForcedSourceStubBuild: Bool {
        RecklessBackend.current == .stub
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

    // A RECORDED skip, never a silent pass: this is the package's only
    // real-engine test, and its old body early-returned green both when the
    // gitignored net wasn't staged (every CI/fresh checkout) and on the
    // forced-source macOS arm — a suite run could show 100% pass with zero
    // engine code executed. `.enabled(if:)` (the mechanism the sibling
    // SwiftStockfish suite uses) makes the not-run state visible as a skip.
    @Test(
        "uci → uciok, isready → readyok, go → bestmove, end-to-end",
        .enabled(
            if: RecklessEngineSmokeTests.stagedNetDir != nil
                && !RecklessEngineSmokeTests.isForcedSourceStubBuild,
            "needs the gitignored dev net staged in rust/networks and a real (non-stub) engine link"
        )
    )
    func fullHandshake() async throws {
        let netDir = try #require(Self.stagedNetDir)
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

    // The restart contract (fork swiftreckless-v0.9.1): a clean shutdown
    // joins the engine thread, unloads the ~60 MB net, and releases the
    // process engine slot — so a SECOND full lifetime must work. This is the
    // package-level guarantee the host app's background engine shed depends
    // on (shed on background, respawn on demand).
    @Test(
        "second engine lifetime after shutdown: fresh handshake and search",
        .enabled(
            if: RecklessEngineSmokeTests.stagedNetDir != nil
                && !RecklessEngineSmokeTests.isForcedSourceStubBuild,
            "needs the gitignored dev net staged in rust/networks and a real (non-stub) engine link"
        )
    )
    func restartAfterShutdown() async throws {
        let netDir = try #require(Self.stagedNetDir)
        guard let first = RecklessEngine(networkDirectory: netDir) else {
            Issue.record("first RecklessEngine lifetime failed to start")
            return
        }
        first.isReady()
        #expect(await awaitLine(first, timeout: .seconds(10)) { $0 == "readyok" },
                "first lifetime never answered readyok")
        // shutdown() is synchronous through rk_destroy: it joins the engine
        // thread before returning, so the slot is free when it returns.
        first.shutdown()

        guard let second = RecklessEngine(networkDirectory: netDir) else {
            Issue.record("second RecklessEngine lifetime was rejected after a clean shutdown")
            return
        }
        defer { second.shutdown() }
        second.uci()
        #expect(await awaitLine(second, timeout: .seconds(10)) { $0 == "uciok" },
                "restarted engine never answered uciok")
        second.isReady()
        #expect(await awaitLine(second, timeout: .seconds(5)) { $0 == "readyok" },
                "restarted engine never answered readyok")
        second.send("go depth 1")
        #expect(await awaitLine(second, timeout: .seconds(30)) { $0.hasPrefix("bestmove") },
                "restarted engine never produced a bestmove")
    }
}
