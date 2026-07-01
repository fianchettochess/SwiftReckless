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
                for await line in engine.output where pred(line) { return true }
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
        guard let netDir = Self.stagedNetDir else {
            // Net is gitignored; a fresh checkout / CI without it skips (passes).
            return
        }
        guard let engine = RecklessEngine(networkDirectory: netDir) else {
            Issue.record("RecklessEngine(networkDirectory:) returned nil — net present but engine failed to start")
            return
        }
        defer { engine.quit() }

        engine.uci()
        #expect(await awaitLine(engine, timeout: .seconds(10)) { $0 == "uciok" }, "no uciok")

        engine.isReady()
        #expect(await awaitLine(engine, timeout: .seconds(5)) { $0 == "readyok" }, "no readyok")

        engine.send("go depth 1")
        #expect(await awaitLine(engine, timeout: .seconds(30)) { $0.hasPrefix("bestmove") }, "no bestmove")
    }
}
