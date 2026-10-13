// SHA-256 for network-file integrity on platforms without CryptoKit.
// Keep the Swift value API while performing compression in a small portable C
// target: debug Swift array bounds/exclusivity checks made cold verification
// take over a minute on Android. No external crypto package or CPU ISA needed.
// INTENTIONAL MIRROR: update both engine packages and their hash tests together.
import Foundation
import CRecklessNetworkHash

/// A streaming, value-semantic SHA-256 hasher (FIPS 180-4).
/// The existing init/update/finalize API is preserved. Copies hold independent
/// state and streaming retains at most one partial 64-byte block.
public struct VendoredSHA256 {
    private var context = rk_network_hash_context()

    public init() {
        rk_network_hash_init(&context)
    }

    /// Feed any number of chunks; empty chunks do not affect the digest.
    public mutating func update(data: Data) {
        data.withUnsafeBytes { bytes in
            rk_network_hash_update(&context, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
    }

    /// Finalize this hasher and return its 32-byte digest in big-endian order.
    public mutating func finalize() -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: 32)
        digest.withUnsafeMutableBufferPointer { bytes in
            rk_network_hash_finalize(&context, bytes.baseAddress!)
        }
        return digest
    }
}
