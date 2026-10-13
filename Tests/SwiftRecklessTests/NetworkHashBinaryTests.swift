import Foundation
import XCTest
@testable import SwiftReckless

final class NetworkHashBinaryTests: XCTestCase {
    private func hex(_ digest: [UInt8]) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    func testBinaryVectorsAtPaddingBoundariesAndEveryChunkSize() {
        // Expected digests were independently computed with Python hashlib.
        let vectors: [(Int, String)] = [
            (0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            (1, "e7cf46a078fed4fafd0b5e3aff144802b853f8ae459a4f0c14add3314b7cc3a6"),
            (55, "2900465fcb533e05a158fd2b3be0e5e3b03740d83060aa3580e0d98a96bf2384"),
            (56, "31454ff48ef36af2f08fd511bdc37d9d5855ac23e992e5ff5445cb6b7674a674"),
            (63, "5f6401b96532c36de4e65beec0409b69b1d181864c8009b7a04f43e5d56350d1"),
            (64, "94eb5de4943613fd048dc93393ab06877405faa39c11f53e9386083339833e7e"),
            (65, "fc518669b6eb4b4dd91827ecacef86689c725bd5bab888fd3b26dbb196eec954"),
            (119, "b0dc41b1a384e2f1203f0351b38fbeaafceef577ce1191d5bfc25da39f721eae"),
            (120, "5df24dd802ac26132ce608dcb5f09841eef039ee0f152acf98d26d17fe4e88e6"),
            (127, "0fe729ff19257bd6fec853acc2ea355f6b34b58e6c0f684c3e188fcdfcd9baae"),
            (128, "0aedd4856f8eba0963627336ad5144a9a7dbe12498e6066f0165fc97d8ddee4c"),
            (129, "4f1757ae4bffbae86d775b831765b75af154d52f7deaa46dd378051a2d3ad57f"),
            (255, "3c835ac0bba7147eaa568a76183d465e72ac456df24b55e01d44dc87be05a971"),
            (4097, "042a02b55ba342cdd30322331816b6e4bca073f33bdb80149dc74a6f949802f4"),
        ]
        for (count, expected) in vectors {
            let data = Data((0..<count).map { UInt8(($0 * 37 + 11) % 256) })
            for chunk in [1, 3, 7, 55, 64, 65, 127, 1024] {
                var hasher = VendoredSHA256()
                hasher.update(data: Data())
                var offset = 0
                while offset < data.count {
                    let end = min(offset + chunk, data.count)
                    hasher.update(data: data.subdata(in: offset..<end))
                    hasher.update(data: Data())
                    offset = end
                }
                XCTAssertEqual(hex(hasher.finalize()), expected, "bytes=\(count), chunk=\(chunk)")
            }
        }
    }

    func testCopiesForkIndependentlyWithFullAndPartialBlocks() {
        for count in [17, 64, 81] {
            let prefix = Data((0..<count).map { UInt8(($0 * 37 + 11) % 256) })
            var original = VendoredSHA256()
            original.update(data: prefix)
            var copy = original
            original.update(data: Data("left".utf8))
            copy.update(data: Data("right".utf8))
            let expected: [Int: (String, String)] = [
                17: ("bd84f13d5aab4f16320412bfacbb4a2d6f1e9c2e1d6d1f290ce8f0bfd4a1c1e8", "95590ffc20eb1d43c0e8778af930c3b568c05c7377b99dd172ec95bb813b361c"),
                64: ("a1224896a3d992a46b49a35ca4e6d30a1f7319a491b9e7cba48e13f084b9502a", "186989bd5ea1c5c83e63810fdf0d023d980b2f3b5cc12277f4307acdad4e42b8"),
                81: ("30d78276e2f6a19bf0aeb21950664b4ad783b006c7a97475b356064ad516a89b", "e28de2f97421bfbcca270f95d1b21ac168bf797cacefdb8a468c2dc9e7649591"),
            ]
            XCTAssertEqual(hex(original.finalize()), expected[count]!.0)
            XCTAssertEqual(hex(copy.finalize()), expected[count]!.1)
        }
    }
}
