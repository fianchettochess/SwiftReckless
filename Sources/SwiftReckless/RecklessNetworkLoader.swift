//
//  RecklessNetworkLoader.swift
//  SwiftReckless
//
//  Downloads and verifies the Reckless NNUE network file at runtime.
//  The net is NEVER committed to this repo (same policy as the Stockfish nets
//  in SwiftStockfish / Fianchetto).
//
//  INTENTIONAL MIRROR of SwiftStockfish's StockfishNetworkLoader.swift: the
//  two packages must stay dependency-free of each other, so the download box,
//  the downloadToTemp staging pipeline, and the pruning sweep are maintained
//  as deliberate twins. CHANGE THEM TOGETHER — a hardening fix landed in one
//  loader must be ported to the other in the same session (this rule exists
//  because the two copies drifted once already). Intentional differences:
//  Stockfish manages a manifest of several `nn-<12hex>.nnue` nets verified by
//  SHA-256 *prefix* with a fishtest→GitHub source fallback; Reckless manages
//  one `v<NN>-<8hex>.nnue` net verified against a pinned *full* SHA-256 from
//  a single URL, so its LoaderError carries download context Stockfish
//  expresses via allSourcesFailed.
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

/// Cancellation bridge for the callback-based URLSession API. Parent-task
/// cancellation can race task creation, so the state and task reference share
/// one lock. Deliberate twin of SwiftStockfish's StockfishDownloadTaskBox —
/// change them together (see the mirror note in the file header).
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

    /// The net this instance ensures. Always ``network`` in production; the
    /// internal seam below substitutes a synthetic net for offline tests.
    private let requiredNetwork: Network

    private let session: URLSession

    public init() {
        self.init(network: Self.network)
    }

    /// Testability seam mirroring StockfishNetworkLoader's injectable
    /// manifest: offline tests substitute a synthetic net whose pinned full
    /// SHA-256 matches a fixture already on disk, so `ensure` completes its
    /// prune/verify work without ever reaching the download path.
    init(network: Network) {
        self.requiredNetwork = network
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Ensure `directory` contains the required NNUE network.
    ///
    /// First PRUNES the directory: stale `v…-….nnue` nets from a previous
    /// Reckless version and orphaned `.….nnue.<UUID>.part` download staging
    /// files left by a crashed/killed earlier run are deleted.
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

        let net = requiredNetwork

        // 1b. Prune stale nets and orphaned download staging files.
        try pruneStaleFiles(in: directory, keeping: net.filename, fm: fm)
        try Task.checkCancellation()

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

    // MARK: - Pruning

    /// Deliberate twin of StockfishNetworkLoader.pruneStaleNetworks — change
    /// them together (see the mirror note in the file header).
    private func pruneStaleFiles(
        in directory: URL,
        keeping requiredName: String,
        fm: FileManager
    ) throws {
        let contents: [URL]
        do {
            // No `.skipsHiddenFiles`: the download staging files this pruner
            // must reclaim are dot-prefixed (hidden) by design — see below.
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            // A directory we just created should be enumerable; treat a failure
            // here as fatal so we don't silently skip pruning.
            throw LoaderError.fileSystem("could not enumerate \(directory.path): \(error.localizedDescription)")
        }

        for url in contents {
            let name = url.lastPathComponent

            // Orphaned download staging files: downloadToTemp stages in-flight
            // bytes at `.v<NN>-<hex>.nnue.<UUID>.part`; in-process cleanup is a
            // `defer` in ensure(), so a crash/kill during the verify/install
            // window (which includes SHA-256 hashing the ~20-45 MB net)
            // orphans the file forever. Any `.part` present NOW is from a dead
            // run: live staging files exist only during a download, and
            // downloads start strictly after this prune within the same
            // `ensure` call (concurrent `ensure` calls on one directory are
            // not supported). The three-piece match is exact to the staging
            // scheme so no unrelated hidden file is ever touched.
            if name.hasPrefix(".v"), name.contains(".nnue."), name.hasSuffix(".part") {
                try? fm.removeItem(at: url)
                continue
            }

            // Stale nets from a previous Reckless version (`v53-….nnue` after
            // an upgrade to v54): prune by Reckless's `v…-….nnue` name shape,
            // leaving every non-net file untouched.
            guard name.hasPrefix("v"), name.contains("-"), name.hasSuffix(".nnue") else { continue }
            if name != requiredName {
                try? fm.removeItem(at: url)
            }
        }
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
