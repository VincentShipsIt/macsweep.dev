import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MacSweepCore

struct SimilarPhotosModuleTests {
    // MARK: - Signature from a real image (thumbnail decode path)

    /// Writes an 8-bit grayscale PNG whose pixel at (x, y) is `pixel(x, y)`.
    private func writeGrayPNG(side: Int, to url: URL, pixel: (Int, Int) -> UInt8) throws {
        var bytes = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                bytes[y * side + x] = pixel(x, y)
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = try #require(CGContext(
            data: &bytes,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let image = try #require(context.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func makeProducesStableSignatureFromThumbnail() throws {
        let temp = try TempTestDirectory(prefix: "MacSweepSimilarPhotoSig")

        // A left-dark / right-bright split — a clear, downsample-robust pattern.
        let gradientA = temp.appendingPathComponent("a.png")
        let gradientCopy = temp.appendingPathComponent("a-copy.png")
        try writeGrayPNG(side: 128, to: gradientA) { x, _ in x < 64 ? 10 : 240 }
        try writeGrayPNG(side: 128, to: gradientCopy) { x, _ in x < 64 ? 10 : 240 }

        // A visually different image (top-dark / bottom-bright split).
        let flipped = temp.appendingPathComponent("b.png")
        try writeGrayPNG(side: 128, to: flipped) { _, y in y < 64 ? 10 : 240 }

        let sigA = try #require(SimilarPhotoSignature.make(from: gradientA))
        let sigCopy = try #require(SimilarPhotoSignature.make(from: gradientCopy))
        let sigB = try #require(SimilarPhotoSignature.make(from: flipped))

        // Byte-identical images → identical signature (deterministic thumbnail hash).
        #expect(sigA == sigCopy)
        // A clearly different image → a different perceptual hash.
        #expect(sigA.hammingDistance(to: sigB) > 0)
    }

    @Test func hammingDistanceIncludesAspectRatioDelta() {
        let lhs = SimilarPhotoSignature(bits: 0b1111, aspectRatioBucket: 10)
        let rhs = SimilarPhotoSignature(bits: 0b1101, aspectRatioBucket: 12)

        #expect(lhs.hammingDistance(to: rhs) == 3)
    }

    @Test func grouperClustersNearMatches() {
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

        #expect(groups.count == 1)
        #expect(groups[0].photos.count == 2)
    }

    @Test func selectorKeepsOldestThenLargestPhoto() {
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

        #expect(selected == [newer])
    }
}
