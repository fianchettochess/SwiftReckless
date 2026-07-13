//
//  RecklessNetworkLoaderCancellationTests.swift
//  SwiftRecklessTests
//
//  Hermetic tests for the download-cancellation machinery and the staged-copy
//  happy path in RecklessNetworkLoader. NOTHING here touches the real
//  network: the loader is built over an injected `Transport` closure (the
//  loader's internal test seam) that either parks until cancelled or writes
//  canned bytes to the staging file.
//
//  Why a transport seam and not a stub URLProtocol: swift-corelibs-foundation
//  does not reliably honor custom URLProtocol subclasses for download tasks —
//  on Linux a stub's served bytes never materialize as a downloaded file, so
//  the request escapes to the REAL network and fails. The transport seam is
//  in-process on every platform. Deliberate twin of SwiftStockfish's
//  StockfishNetworkLoaderCancellationTests (see the intentional-mirror header
//  in RecklessNetworkLoader.swift).
//
//  Contracts under test:
//    - Cancellation before the download path is reached: the transport is
//      never invoked and no staging file appears.
//    - Cancellation mid-download: `ensure` throws CancellationError, leaves
//      no `.part` staging file, and — Reckless having exactly one pinned
//      source, no fallback — the transport was invoked exactly once.
//    - The staged-copy happy path: a (stubbed) successful download is staged,
//      verified against the pinned full SHA-256, installed, and its `.part`
//      staging file removed.
//

import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SwiftReckless

@Suite("RecklessNetworkLoader cancellation (hermetic)")
struct RecklessNetworkLoaderCancellationTests {

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Every `.part` staging file in `dir` (hidden files included).
    private func partFiles(in dir: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.lastPathComponent.hasSuffix(".part") }
    }

    /// A well-formed net spec that no bytes can hash to, forcing `ensure`
    /// down the download path. Its URL is synthetic: nothing in this suite
    /// may reach a real host, and the injected transports never dial out.
    private var absentNet: RecklessNetworkLoader.Network {
        RecklessNetworkLoader.Network(
            filename: "v54-00000000.nnue",
            sha256: String(repeating: "0", count: 64),
            downloadURL: URL(string: "https://invalid.example/v54-00000000.nnue")!
        )
    }

    /// A transport that records the call, then parks until the surrounding
    /// task is cancelled — `Task.sleep` then throws CancellationError, exactly
    /// as the production URLSession transport reports a cancelled transfer.
    /// It never writes to the staging URL, like a transfer whose bytes never
    /// finished arriving.
    private func parkingTransport(spy: TransportSpy) -> RecklessNetworkLoader.Transport {
        { url, stagingURL in
            spy.record(url: url, stagingURL: stagingURL)
            // Park (~1 hour). Reaching the sleep's end means a test hung for
            // an hour without cancelling — fail loudly rather than pretend.
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            Issue.record("parking transport was never cancelled")
            throw URLError(.badServerResponse)
        }
    }

    @Test("a pre-cancelled ensure throws CancellationError before any transport call or staging file")
    func preCancelledEnsureNeverTouchesTransportOrDisk() async throws {
        let spy = TransportSpy()
        let dir = makeTempDir()
        defer { remove(dir) }
        let loader = RecklessNetworkLoader(
            network: absentNet, transport: parkingTransport(spy: spy)
        )

        let task = Task {
            // Deterministic ordering: enter `ensure` only after cancellation
            // has landed, so the first Task.checkCancellation() must throw.
            while !Task.isCancelled { await Task.yield() }
            return try await loader.ensure(in: dir)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(spy.requestedURLs.isEmpty,
                "no download may be started after cancellation")
        #expect(partFiles(in: dir).isEmpty, "no staging file may be left behind")
    }

    @Test("cancelling mid-download throws CancellationError, leaves no staging file, and calls the single-source transport exactly once")
    func cancelDuringDownloadCleansUpAfterOneTransportCall() async throws {
        let spy = TransportSpy()
        let dir = makeTempDir()
        defer { remove(dir) }
        let net = absentNet
        let loader = RecklessNetworkLoader(
            network: net, transport: parkingTransport(spy: spy)
        )

        let task = Task { try await loader.ensure(in: dir) }

        // Wait until the download is genuinely in flight.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while spy.requestedURLs.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(spy.requestedURLs.count == 1, "the download should be in flight")

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        // Reckless has ONE pinned source (no fallback to advance to), so a
        // cancelled download must leave exactly the one transport call.
        #expect(spy.requestedURLs == [net.downloadURL],
                "cancellation must not retry the single pinned source")
        #expect(partFiles(in: dir).isEmpty, "no staging file may be left behind")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(net.filename).path),
                "a cancelled download must not install a net")
    }

    @Test("a stubbed successful download stages, verifies, installs, and removes the .part staging file")
    func successfulDownloadInstallsAndCleansStaging() async throws {
        let content = Data("swiftreckless-hermetic-download-fixture".utf8)
        let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let net = RecklessNetworkLoader.Network(
            filename: "v54-\(String(sha.prefix(8))).nnue",
            sha256: sha,
            downloadURL: URL(string: "https://invalid.example/v54-\(String(sha.prefix(8))).nnue")!
        )

        let spy = TransportSpy()
        let dir = makeTempDir()
        defer { remove(dir) }
        // A transport that "downloads" by writing the fixture bytes to the
        // loader's staging URL and reporting a 200 — the success contract of
        // the production URLSession transport, minus the network.
        let transport: RecklessNetworkLoader.Transport = { url, stagingURL in
            spy.record(url: url, stagingURL: stagingURL)
            try content.write(to: stagingURL)
            guard let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(content.count)"]
            ) else { throw URLError(.badServerResponse) }
            return response
        }
        let loader = RecklessNetworkLoader(network: net, transport: transport)

        let installed = try await loader.ensure(in: dir)

        // Staged: the loader handed the transport a hidden `.part` staging
        // path inside the nets directory, named for this net.
        #expect(spy.stagingURLs.count == 1)
        if let staging = spy.stagingURLs.first {
            #expect(staging.deletingLastPathComponent().path == dir.path,
                    "staging must happen alongside the destination (same volume)")
            #expect(staging.lastPathComponent.hasPrefix(".\(net.filename)."),
                    "staging file must be the hidden .<net>.<UUID>.part scheme")
            #expect(staging.lastPathComponent.hasSuffix(".part"))
        }

        // Verified + installed: the exact fixture bytes (whose pinned full
        // SHA-256 the loader checked) now live at the returned destination.
        #expect(installed == dir.appendingPathComponent(net.filename))
        #expect(try Data(contentsOf: installed) == content, "the verified bytes must be installed")

        // Staging cleaned + single fetch: the `.part` is gone and the one
        // pinned URL was asked exactly once.
        #expect(partFiles(in: dir).isEmpty, "the .part staging file must be removed after install")
        #expect(spy.requestedURLs == [net.downloadURL],
                "the single pinned URL must be fetched exactly once")
    }
}
