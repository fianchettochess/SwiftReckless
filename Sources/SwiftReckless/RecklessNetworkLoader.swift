//
//  RecklessNetworkLoader.swift
//  SwiftReckless
//
//  Downloads and verifies the Reckless NNUE network file at runtime.
//  The net is NEVER committed to this repo (same policy as the Stockfish nets
//  in SwiftStockfish / Fianchetto).
//
//  USAGE:
//    let support = FileManager.default.urls(for: .applicationSupportDirectory,
//                                           in: .userDomainMask)[0]
//    let dir = support.appendingPathComponent("reckless-nets")
//    _ = try await RecklessNetworkLoader().ensure(in: dir)
//    guard let engine = RecklessEngine(networkDirectory: dir) else { return }
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Cancellation bridge for URLSession's callback-based download API. The
/// cancellation handler may run before or after the task is installed, so both
/// state and the task reference are protected by one lock.
private final class RecklessDownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var cancellationRequested = false

    func installAndResume(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancellationRequested
        lock.unlock()

        task.resume()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

/// Downloads and verifies the Reckless NNUE network.
///
/// The network filename encodes a SHA-256 prefix in its name (the same scheme
/// Stockfish uses): `v54-5478683c.nnue`. The loader verifies the complete
/// pinned SHA-256 digest on every supported platform.
public struct RecklessNetworkLoader: Sendable {

    // ── Current network spec ──────────────────────────────────────────────────
    // The net is loaded at RUNTIME (its path is passed to rk_create), not baked
    // into the crate. When Reckless upgrades its net, update this constant only
    // — no Rust rebuild is needed.

    /// The single NNUE network Reckless v0.9 requires.
    public static let network = Network(
        filename: "v54-5478683c.nnue",
        // Full SHA-256 of the file.  The first 8 hex chars match the filename.
        // Verified with: shasum -a 256 networks/v54-5478683c.nnue
        sha256: "5478683cb1bababde29ae8f29468a99846726548fc6a0ed54cac40ab6d38efbf",
        // Canonical download URL from the RecklessNetworks releases page.
        downloadURL: URL(string:
            "https://github.com/codedeliveryservice/RecklessNetworks/releases/download/networks/v54-5478683c.nnue"
        )!
    )

    /// A descriptor for one NNUE network.
    public struct Network: Sendable {
        public let filename: String
        /// Full SHA-256 hex string of the network file.
        public let sha256: String
        public let downloadURL: URL

        /// First 8 hex characters of the SHA-256 (embedded in the filename).
        public var shaPrefix: String { String(sha256.prefix(8)) }
    }

    /// Errors thrown by ``ensure(in:progress:)``.
    public enum LoaderError: Error, Sendable {
        /// The downloaded file's complete SHA-256 did not match the manifest.
        case checksumMismatch(String)
        /// The download failed.
        case downloadFailed(String)
        /// A filesystem operation failed.
        case fileSystem(String)
    }

    /// Progress snapshot for an in-flight download.
    public struct Progress: Sendable {
        public let bytesDownloaded: Int64
        public let totalBytes: Int64

        /// `nil` when the server did not send a `Content-Length`.
        public var fractionCompleted: Double? {
            guard totalBytes > 0 else { return nil }
            return min(1.0, Double(bytesDownloaded) / Double(totalBytes))
        }
    }

    private let session: URLSession

    public init() {
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Ensure `directory` contains the required NNUE network.
    ///
    /// If the file is already present and passes full SHA-256 verification,
    /// nothing is downloaded (idempotent).  Otherwise the file is downloaded
    /// to a temp location, verified, and moved atomically into place.
    /// Cancelling the calling task cancels the active URLSession transfer and
    /// throws `CancellationError`.
    ///
    /// - Parameters:
    ///   - directory: Directory to store the net (created if absent).
    ///   - progress:  Optional progress callback, invoked on the download task
    ///                thread.  Only called when a download occurs.
    /// - Returns: The URL of the verified network file inside `directory`.
    @discardableResult
    public func ensure(
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default

        // 1. Ensure the directory exists.
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LoaderError.fileSystem(
                "could not create \(directory.path): \(error.localizedDescription)"
            )
        }
        try Task.checkCancellation()

        let net = Self.network
        let destination = directory.appendingPathComponent(net.filename)

        // 2. If already present and valid, skip download.
        if fm.fileExists(atPath: destination.path),
           Self.fileMatchesSHA256(destination, expectedSHA256: net.sha256) {
            try Task.checkCancellation()
            return destination
        }

        // Remove an invalid/partial existing file before re-fetching.
        try? fm.removeItem(at: destination)

        // 3. Download.
        let tempURL = try await downloadToTemp(net, in: directory, progress: progress)
        defer { try? fm.removeItem(at: tempURL) }
        try Task.checkCancellation()

        // 4. Verify.
        guard Self.fileMatchesSHA256(tempURL, expectedSHA256: net.sha256) else {
            throw LoaderError.checksumMismatch(net.filename)
        }
        try Task.checkCancellation()

        // 5. Atomic install.
        do {
            try fm.moveItem(at: tempURL, to: destination)
        } catch {
            throw LoaderError.fileSystem(
                "could not install \(net.filename): \(error.localizedDescription)"
            )
        }

        return destination
    }

    // MARK: - Download

    private func downloadToTemp(
        _ net: Network,
        in directory: URL,
        progress: (@Sendable (Progress) -> Void)?
    ) async throws -> URL {
        let tempURL = directory.appendingPathComponent(
            ".\(net.filename).\(UUID().uuidString).part"
        )

        let taskBox = RecklessDownloadTaskBox()
        try Task.checkCancellation()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: net.downloadURL) { downloadedURL, response, error in
                    if let error {
                        if taskBox.wasCancelled {
                            cont.resume(throwing: CancellationError())
                        } else {
                            cont.resume(throwing: LoaderError.downloadFailed(
                                "\(net.filename): \(error.localizedDescription)"
                            ))
                        }
                        return
                    }
                    guard let downloadedURL else {
                        cont.resume(throwing: LoaderError.downloadFailed(
                            "\(net.filename): response contained no file"
                        ))
                        return
                    }
                    if let http = response as? HTTPURLResponse,
                       !(200...299).contains(http.statusCode) {
                        cont.resume(throwing: LoaderError.downloadFailed(
                            "\(net.filename): HTTP \(http.statusCode)"
                        ))
                        return
                    }

                    // Relocate NOW (OS deletes the system temp URL when this handler returns).
                    let fm = FileManager.default
                    try? fm.removeItem(at: tempURL)
                    do {
                        do {
                            try fm.moveItem(at: downloadedURL, to: tempURL)
                        } catch {
                            try fm.copyItem(at: downloadedURL, to: tempURL)
                        }
                    } catch {
                        cont.resume(throwing: LoaderError.fileSystem(
                            "could not stage download for \(net.filename): \(error.localizedDescription)"
                        ))
                        return
                    }

                    if let progress {
                        let total = (response?.expectedContentLength ?? -1) > 0
                            ? response!.expectedContentLength
                            : -1
                        progress(Progress(bytesDownloaded: max(total, 0), totalBytes: total))
                    }

                    cont.resume(returning: tempURL)
                }
                taskBox.installAndResume(task)
            }
        }, onCancel: {
            taskBox.cancel()
        })
    }

    // MARK: - Verification

    /// Verify a file's SHA-256 matches the given complete 64-hex digest.
    /// Internal so the offline tests can exercise the exact production path.
    static func fileMatchesSHA256(_ url: URL, expectedSHA256: String) -> Bool {
        guard expectedSHA256.count == 64,
              expectedSHA256.allSatisfy({ $0.isHexDigit })
        else { return false }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == expectedSHA256.lowercased()
    }
}
