//
//  SHA256Tests.swift
//  SwiftRecklessTests
//
//  NIST FIPS 180-4 vectors for the vendored SHA256, plus streaming
//  equivalence. This is the proof that the pure-Swift digest matches the
//  published standard before it is trusted to gate NNUE network-file
//  installation. Runs on every `swift test` (host platform is irrelevant:
//  the implementation is independent of CryptoKit).
//

import XCTest
@testable import SwiftReckless

final class SHA256Tests: XCTestCase {
    private func hex(_ digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func digest(_ string: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(string.utf8))
        return hex(hasher.finalize())
    }

    private func digestChunked(_ string: String, chunk: Int) -> String {
        let data = Data(string.utf8)
        var hasher = SHA256()
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            hasher.update(data: data.subdata(in: offset..<end))
            offset = end
        }
        return hex(hasher.finalize())
    }

    func testEmptyVector() {
        XCTAssertEqual(
            digest(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testABCVector() {
        XCTAssertEqual(
            digest("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testTwoBlockVector() {
        XCTAssertEqual(
            digest("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testMillionA() {
        XCTAssertEqual(
            digest(String(repeating: "a", count: 1_000_000)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testPaddingBoundariesMatchChunkedStreaming() {
        for (repeats, chunk) in [(55, 3), (56, 7), (63, 64), (64, 64), (65, 1), (119, 16)] {
            let input = String(repeating: "x", count: repeats)
            XCTAssertEqual(
                digest(input),
                digestChunked(input, chunk: chunk),
                "whole vs chunked disagree at \(repeats) bytes"
            )
        }
    }
}
