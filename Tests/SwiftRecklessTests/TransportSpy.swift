//
//  TransportSpy.swift
//  SwiftRecklessTests
//
//  Shared test-support for suites that inject a `RecklessNetworkLoader.Transport`
//  (the loader's hermetic download seam — see the seam note on the typealias).
//  Deliberate twin of SwiftStockfishTests' TransportSpy: the two packages stay
//  dependency-free of each other, so the spy is mirrored alongside the loaders
//  (see the intentional-mirror header in RecklessNetworkLoader.swift).
//

import Foundation

/// Thread-safe record of every call an injected transport receives: the
/// source URL asked for and the staging URL the loader handed it.
final class TransportSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _requestedURLs: [URL] = []
    private var _stagingURLs: [URL] = []

    func record(url: URL, stagingURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        _requestedURLs.append(url)
        _stagingURLs.append(stagingURL)
    }

    var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _requestedURLs
    }

    var stagingURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _stagingURLs
    }
}
