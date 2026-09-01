//===----------------------------------------------------------------------===//
// TestSHA256.swift — the test target's half of the loader's hashing seam.
//
// `RecklessNetworkLoader` already resolves this correctly: CryptoKit only
// `#if canImport(CryptoKit)`, and the vendored FIPS 180-4 `VendoredSHA256`
// everywhere else.
//
// The TEST target did not get the same treatment.
// `RecklessNetworkLoaderCancellationTests.swift` still carried
//
//     #if canImport(CryptoKit)
//     import CryptoKit
//     #else
//     import Crypto        // <- swift-crypto
//     #endif
//
// which is the dependency Package.swift removed and says it removed, in the
// block that sets `cryptoPackageDependencies` and `cryptoTargetDependencies` to
// empty arrays — citing, in its own words, the error "no such module 'Crypto'".
// The manifest was cleaned up; this file was missed.
//
// Measured on the first Windows CI run, 2026-09-01:
//
//     RecklessNetworkLoaderCancellationTests.swift:38:8: error: no such module 'Crypto'
//
// This is NOT Windows-specific. Any non-Apple host takes the `#else` arm, so
// Linux compiles it the same way; the package's Linux job runs only on `main`
// and pull requests, so a push to a branch never exercised it and the breakage
// sat unobserved.
//
// A FUNCTION RATHER THAN A TYPEALIAS: `VendoredSHA256` offers the streaming
// shape — `update(data:)` then `finalize()` — and no static `hash(data:)`, so
// aliasing the type would not make the call site compile. It wanted the hex
// digest anyway.
//===----------------------------------------------------------------------===//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import SwiftReckless

/// Lowercase hex SHA-256 of `data`, on every platform the package supports.
func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    return CryptoKit.SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    #else
    var hasher = VendoredSHA256()
    hasher.update(data: data)
    return hasher.finalize()
        .map { String(format: "%02x", $0) }
        .joined()
    #endif
}
