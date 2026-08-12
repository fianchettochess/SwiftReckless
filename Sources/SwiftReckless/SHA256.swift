//===----------------------------------------------------------------------===//
// SHA256.swift — pure, streaming SHA-256 (FIPS 180-4) for NNUE network-file
// verification on platforms without CryptoKit (Android / Linux).
//
// WHY THIS EXISTS. The download step verifies the fetched NNUE net against a
// known-good SHA-256 before installing it. Apple ships CryptoKit
// (`import CryptoKit`, `SHA256()` / `update(data:)` / `finalize()`). Non-Apple
// hosts previously pulled swift-crypto's source-compatible `Crypto` module for
// the same API — but SwiftPM 6.3.3 prunes the `Crypto` product from Android
// cross-builds, treating the name as an OS-provided module with no opt-out
// ("no such module 'Crypto'"). Vendoring a small SHA-256 removes the external
// crypto dependency and the pruning hazard entirely.
//
// The API intentionally mirrors CryptoKit: `SHA256()` then `update(data:)`,
// and `finalize()` returns the 32-byte digest as `[UInt8]`, so the loader's
// call sites are source-identical on every platform. Streaming means a 100MB
// NNUE net is hashed in bounded memory (the loader feeds 1MiB chunks). The
// implementation is a direct transcription of FIPS 180-4 Section 6.2 (the
// published constant table and message schedule), with the NIST vectors
// asserted in SHA256Test.swift.
//
// This is integrity verification for a network-downloaded artifact (same
// guarantee CryptoKit's SHA256 provided). It is not used for key derivation,
// random generation, or any other primitive.
//===----------------------------------------------------------------------===//

import Foundation

/// A streaming SHA-256 hasher (FIPS 180-4).
///
/// Usage mirrors CryptoKit's `SHA256`:
///
///     var hasher = SHA256()
///     hasher.update(data: chunk)
///     let digest: [UInt8] = hasher.finalize() // 32 bytes, big-endian words
public struct SHA256 {
    /// Initial hash values — the fractional parts of the square roots of the
    /// first eight primes (FIPS 180-4 §5.3.3).
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    /// Round constants — the fractional parts of the cube roots of the first
    /// sixty-four primes (FIPS 180-4 §4.2.2).
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// The < 64 bytes awaiting the next 64-byte block (or the final padding).
    private var buffer: [UInt8] = []

    /// Total message bytes fed via `update`. Needed for the 64-bit length word
    /// appended during padding.
    private var totalLength: UInt64 = 0

    public init() {}

    /// Feeds [data] into the digest. Safe to call any number of times; only
    /// full 64-byte blocks are compressed eagerly, so memory stays `Data`-chunk
    /// bounded rather than whole-message bounded.
    public mutating func update(data: Data) {
        totalLength += UInt64(data.count)
        buffer.append(contentsOf: data)
        while buffer.count >= 64 {
            let block = Array(buffer[..<64])
            buffer.removeFirst(64)
            compress(block)
        }
    }

    /// Finishes the digest (appending FIPS 180-4 padding), returning the
    /// 32-byte big-endian digest.
    public mutating func finalize() -> [UInt8] {
        let messageBits = totalLength &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            buffer.append(UInt8(truncatingIfNeeded: messageBits >> UInt64(shift)))
        }
        while !buffer.isEmpty {
            let block = Array(buffer[..<min(64, buffer.count)])
            buffer.removeFirst(block.count)
            compress(block)
        }
        var digest: [UInt8] = []
        digest.reserveCapacity(32)
        for word in state {
            for shift in stride(from: 24, through: 0, by: -8) {
                digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return digest
    }

    @inline(__always)
    private func rotateRight(_ value: UInt32, _ places: UInt32) -> UInt32 {
        (value >> places) | (value << (32 &- places))
    }

    /// Compresses one 64-byte block into `state` (FIPS 180-4 §6.2.2).
    private mutating func compress(_ block: [UInt8]) {
        precondition(block.count == 64)

        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let base = i * 4
            w[i] = (UInt32(block[base]) << 24)
                | (UInt32(block[base + 1]) << 16)
                | (UInt32(block[base + 2]) << 8)
                | UInt32(block[base + 3])
        }
        for i in 16..<64 {
            let s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for i in 0..<64 {
            let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = h &+ sum1 &+ choice &+ Self.roundConstants[i] &+ w[i]
            let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = sum0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }
}
