import Testing
import Foundation
@testable import SwiftReckless

// ─────────────────────────────────────────────────────────────────────────────
// Suite 1 — Pure-logic / offline tests (always run, no engine required)
// ─────────────────────────────────────────────────────────────────────────────

@Suite("RecklessNetworkLoader offline tests")
struct NetworkLoaderTests {

    @Test("Network spec has correct filename and SHA prefix")
    func networkSpec() {
        let net = RecklessNetworkLoader.network
        #expect(net.filename == "v60-7f587dfb.nnue")
        #expect(net.shaPrefix == "7f587dfb")
        #expect(net.downloadURL.scheme == "https")
    }

    @Test("Network filename encodes SHA prefix")
    func filenameEncodesSHA() {
        let net = RecklessNetworkLoader.network
        // The filename convention is "v<n>-<sha8chars>.nnue"
        let parts = net.filename
            .replacingOccurrences(of: ".nnue", with: "")
            .split(separator: "-")
        #expect(parts.count == 2)
        #expect(String(parts[1]) == net.shaPrefix)
    }

    @Test("Loader constructs correctly")
    func loaderInit() {
        let loader = RecklessNetworkLoader()
        // Sanity-check: initialising the loader does not crash.
        let _ = loader
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite 2 — Engine init tests (offline; engine is STUBBED → always returns nil)
// ─────────────────────────────────────────────────────────────────────────────

@Suite("RecklessEngine init tests")
struct EngineInitTests {

    @Test("Engine returns nil while FFI is stubbed")
    func engineInitReturnsNilWhenStubbed() {
        // The Rust FFI is stubbed: rk_ffi_create returns NULL, so
        // RecklessEngine.init? returns nil.  This test documents and asserts
        // the expected behaviour of the scaffold.  It will need updating once
        // the real engine is wired in (it will return a non-nil engine, and
        // this test should be changed to use a real network path).
        let fakeNetURL = URL(fileURLWithPath: "/tmp/nonexistent.nnue")
        let engine = RecklessEngine(networkFile: fakeNetURL)
        #expect(engine == nil, "Expected nil while FFI is stubbed")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite 3 — Integration tests (gated; require SWIFTRECKLESS_INTEGRATION=1)
// ─────────────────────────────────────────────────────────────────────────────
// These tests download the NNUE net and run a live engine.  Gate them behind
// an environment variable so they don't fire on a plain `swift test`.
//
// Run with:
//   SWIFTRECKLESS_INTEGRATION=1 swift test --filter "RecklessIntegrationTests"

@Suite("RecklessEngine integration tests")
struct RecklessIntegrationTests {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SWIFTRECKLESS_INTEGRATION"] == "1"
    }

    @Test("Engine emits uciok after uci command")
    func uciHandshake() async throws {
        guard isEnabled else { return }

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let netDir = support.appendingPathComponent("SwiftRecklessTests")
        let netURL = try await RecklessNetworkLoader().ensure(in: netDir)

        guard let engine = RecklessEngine(networkFile: netURL) else {
            Issue.record("Engine returned nil — is the FFI wired in?")
            return
        }

        engine.uci()

        var gotUciOk = false
        for await line in engine.output {
            if line == "uciok" { gotUciOk = true; break }
        }
        #expect(gotUciOk)

        engine.quit()
    }

    @Test("Engine responds readyok to isready")
    func isReadyHandshake() async throws {
        guard isEnabled else { return }

        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let netDir = support.appendingPathComponent("SwiftRecklessTests")
        let netURL = try await RecklessNetworkLoader().ensure(in: netDir)

        guard let engine = RecklessEngine(networkFile: netURL) else {
            Issue.record("Engine returned nil — is the FFI wired in?")
            return
        }

        engine.uci()
        // Drain uci response.
        for await line in engine.output { if line == "uciok" { break } }

        engine.isReady()
        var gotReadyOk = false
        for await line in engine.output {
            if line == "readyok" { gotReadyOk = true; break }
        }
        #expect(gotReadyOk)

        engine.quit()
    }
}
