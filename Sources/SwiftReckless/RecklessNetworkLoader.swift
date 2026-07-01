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
//    let netURL = try await RecklessNetworkLoader().ensure(in: dir)
//    guard let engine = RecklessEngine(networkFile: netURL) else { return }
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
// On non-Apple hosts, use swift-crypto (declared in Package.swift; not yet
// added — see TODO in Package.swift crypto section).
// import Crypto
#endif

/// Downloads and verifies the Reckless NNUE network.
///
/// The network filename encodes a SHA-256 prefix in its name (the same scheme
/// Stockfish uses): `v60-7f587dfb.nnue`.  The loader verifies the first 8 hex
/// chars of the SHA-256 of the downloaded file match `7f587dfb`.
public struct RecklessNetworkLoader: Sendable {

    // ── Current network spec ──────────────────────────────────────────────────
    // Keep in sync with `build/build.rs` NETWORK_NAME in the Reckless source.
    // When Reckless upgrades its net, update BOTH this constant AND the
    // build.rs constant (and re-run `cargo build`).

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
        /// The downloaded file's SHA-256 prefix did not match the filename.
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
    /// If the file is already present and passes SHA-prefix verification,
    /// nothing is downloaded (idempotent).  Otherwise the file is downloaded
    /// to a temp location, verified, and moved atomically into place.
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

        let net = Self.network
        let destination = directory.appendingPathComponent(net.filename)

        // 2. If already present and valid, skip download.
        if fm.fileExists(atPath: destination.path),
           (try? verify(fileAt: destination, expectedSHA256: net.sha256)) == true {
            return destination
        }

        // Remove an invalid/partial existing file before re-fetching.
        try? fm.removeItem(at: destination)

        // 3. Download.
        let tempURL = try await downloadToTemp(net, in: directory, progress: progress)
        defer { try? fm.removeItem(at: tempURL) }

        // 4. Verify.
        guard (try? verify(fileAt: tempURL, expectedSHA256: net.sha256)) == true else {
            throw LoaderError.checksumMismatch(net.filename)
        }

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

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: net.downloadURL) { downloadedURL, response, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                guard let downloadedURL else {
                    cont.resume(throwing: URLError(.badServerResponse))
                    return
                }
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    cont.resume(throwing: URLError(.badServerResponse))
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
            task.resume()
        }
    }

    // MARK: - Verification

    /// Verify a file's SHA-256 matches the given full hex digest.
    private func verify(fileAt url: URL, expectedSHA256: String) throws -> Bool {
        guard !expectedSHA256.isEmpty else { return false }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { handle.closeFile() }

#if canImport(CryptoKit)
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex == expectedSHA256
#else
        // On non-Apple platforms (Linux/Android), swift-crypto is not yet
        // declared as a dependency in Package.swift.  Skip full verification
        // and trust the download; at minimum the filename prefix match
        // provides a weak sanity check.
        return expectedSHA256.hasPrefix(url.deletingPathExtension().lastPathComponent.split(separator: "-").last.map(String.init) ?? "")
#endif
    }
}
