import XCTest
@testable import MacSweepCore

final class SimilarPhotosModuleTests: XCTestCase {
    func testHammingDistanceIncludesAspectRatioDelta() {
        let lhs = SimilarPhotoSignature(bits: 0b1111, aspectRatioBucket: 10)
        let rhs = SimilarPhotoSignature(bits: 0b1101, aspectRatioBucket: 12)

        XCTAssertEqual(lhs.hammingDistance(to: rhs), 3)
    }

    func testGrouperClustersNearMatches() {
        let base = SimilarPhotoCandidate(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/a.jpg"),
            size: 1_000,
            createdDate: .distantPast,
            modifiedDate: .distantPast,
            signature: SimilarPhotoSignature(bits: 0b11110000, aspectRatioBucket: 10)
        )
        let near = SimilarPhotoCandidate(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/b.jpg"),
            size: 900,
            createdDate: .distantPast.addingTimeInterval(10),
            modifiedDate: .distantPast.addingTimeInterval(10),
            signature: SimilarPhotoSignature(bits: 0b11110001, aspectRatioBucket: 10)
        )
        let far = SimilarPhotoCandidate(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/c.jpg"),
            size: 800,
            createdDate: .distantPast.addingTimeInterval(20),
            modifiedDate: .distantPast.addingTimeInterval(20),
            signature: SimilarPhotoSignature(bits: 0b00001111, aspectRatioBucket: 22)
        )

        let groups = SimilarPhotoGrouper(threshold: 3).group([base, near, far])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].photos.count, 2)
    }

    func testSelectorKeepsOldestThenLargestPhoto() {
        let keeper = SimilarPhotoCandidate(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/keeper.jpg"),
            size: 5_000,
            createdDate: .distantPast,
            modifiedDate: .distantPast,
            signature: SimilarPhotoSignature(bits: 7, aspectRatioBucket: 10)
        )
        let newer = SimilarPhotoCandidate(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/newer.jpg"),
            size: 8_000,
            createdDate: .distantPast.addingTimeInterval(60),
            modifiedDate: .distantPast.addingTimeInterval(60),
            signature: SimilarPhotoSignature(bits: 7, aspectRatioBucket: 10)
        )
        let group = SimilarPhotoGroup(id: UUID(), reference: keeper, photos: [newer, keeper])

        let selected = SimilarPhotoSelector().autoSelect(group)

        XCTAssertEqual(selected, [newer])
    }
}
