import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Module for finding visually similar photos.
struct SimilarPhotosModule: ScanModule {
    let id = "similar-photos"
    let name = "Similar Photos"
    let description = "Find visually similar photos that are likely redundant"
    let icon = "photo.stack"

    var searchPaths: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Pictures"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    ]

    var minimumFileSize: Int64 = 204_800
    var similarityThreshold: Int = 8
    var maxImages: Int = 250

    func scan() async throws -> [CleanupItem] {
        (try await scanReviewGroups())
            .flatMap(\.suggestedCleanupItems)
            .sorted { $0.size > $1.size }
    }

    /// Returns complete clusters for manual inspection, including the photo
    /// suggested as the keeper. The regular scan remains limited to the
    /// review-only cleanup candidates consumed by Smart Care and the CLI.
    func scanReviewGroups() async throws -> [FileReviewGroup] {
        let groups = try await similarPhotoGroups()
        let selector = SimilarPhotoSelector()

        return groups.compactMap { group in
            guard let keeper = selector.recommendedKeeper(in: group) else { return nil }
            let items = group.photos.map { photo in
                CleanupItem(
                    id: photo.id,
                    path: photo.path,
                    size: photo.size,
                    type: .file,
                    module: id,
                    moduleName: "Similar to \(group.reference.displayName)",
                    lastModified: photo.modifiedDate
                )
            }
            return FileReviewGroup(
                id: group.id,
                title: group.reference.displayName,
                items: items,
                suggestedKeeperID: keeper.id,
                suggestionReason: "Oldest photo, then largest file"
            )
        }
    }

    private func similarPhotoGroups() async throws -> [SimilarPhotoGroup] {
        let candidates = try await imageCandidates()
        return SimilarPhotoGrouper(threshold: similarityThreshold).group(candidates)
    }

    private func imageCandidates() async throws -> [SimilarPhotoCandidate] {
        let checker = SafetyChecker()
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentTypeKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ]

        var candidates: [SimilarPhotoCandidate] = []

        for root in searchPaths where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            var iterations = 0
            while let url = enumerator.nextObject() as? URL {
                // Photo-library enumeration can run for minutes; without this
                // check a cancelled scan keeps burning IO to completion.
                iterations += 1
                if iterations % 512 == 0 { try Task.checkCancellation() }

                let values = try? url.resourceValues(forKeys: resourceKeys)
                guard values?.isDirectory == false, values?.isSymbolicLink == false else { continue }
                guard values?.contentType?.conforms(to: .image) == true else { continue }
                guard checker.validateForScan(url, moduleID: id).isSafe else { continue }

                let size = values?.diskSize ?? 0
                guard size >= minimumFileSize else { continue }

                guard let signature = SimilarPhotoSignature.make(from: url) else { continue }

                candidates.append(
                    SimilarPhotoCandidate(
                        id: UUID(),
                        path: url,
                        size: size,
                        createdDate: values?.creationDate ?? .distantFuture,
                        modifiedDate: values?.contentModificationDate ?? .distantPast,
                        signature: signature
                    )
                )

                if candidates.count >= maxImages {
                    return candidates
                }
            }
        }

        return candidates
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.recoverable(item.path, module: item.module)
        }
    }
}

struct SimilarPhotoSignature: Hashable, Sendable {
    let bits: UInt64
    let aspectRatioBucket: Int

    static func make(from url: URL) -> SimilarPhotoSignature? {
        // Decode a small thumbnail instead of the full-resolution image: the
        // perceptual hash only needs an 8×8 downsample, so paying to decode a
        // 48-megapixel photo into memory was pure waste. `kCGImageSourceThumbnail
        // MaxPixelSize` of 32 gives ImageIO enough detail to feed the 8×8 hash
        // while decoding a tiny fraction of the pixels; `…FromImageAlways` forces
        // a real downsample even when the file embeds no thumbnail.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let size = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: size * size)

        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let average = pixels.reduce(0, { $0 + Int($1) }) / pixels.count
        var bits: UInt64 = 0
        for (index, value) in pixels.enumerated() where Int(value) >= average {
            bits |= 1 << UInt64(index)
        }

        let aspectRatio = Double(width) / Double(height)
        return SimilarPhotoSignature(
            bits: bits,
            aspectRatioBucket: Int((aspectRatio * 10).rounded())
        )
    }

    func hammingDistance(to other: SimilarPhotoSignature) -> Int {
        Int((bits ^ other.bits).nonzeroBitCount) + abs(aspectRatioBucket - other.aspectRatioBucket)
    }
}

struct SimilarPhotoCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    let path: URL
    let size: Int64
    let createdDate: Date
    let modifiedDate: Date
    let signature: SimilarPhotoSignature

    var displayName: String { path.lastPathComponent }
}

struct SimilarPhotoGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    let reference: SimilarPhotoCandidate
    let photos: [SimilarPhotoCandidate]
}

struct SimilarPhotoGrouper {
    let threshold: Int

    func group(_ candidates: [SimilarPhotoCandidate]) -> [SimilarPhotoGroup] {
        var groups: [[SimilarPhotoCandidate]] = []

        for candidate in candidates.sorted(by: { $0.createdDate < $1.createdDate }) {
            if let index = groups.firstIndex(where: { existing in
                guard let reference = existing.first else { return false }
                return candidate.signature.hammingDistance(to: reference.signature) <= threshold
            }) {
                groups[index].append(candidate)
            } else {
                groups.append([candidate])
            }
        }

        return groups.compactMap { photos in
            guard photos.count > 1, let reference = photos.first else { return nil }
            return SimilarPhotoGroup(id: UUID(), reference: reference, photos: photos)
        }
    }
}

struct SimilarPhotoSelector {
    func recommendedKeeper(in group: SimilarPhotoGroup) -> SimilarPhotoCandidate? {
        sortedByKeepPriority(group.photos).first
    }

    func autoSelect(_ group: SimilarPhotoGroup) -> [SimilarPhotoCandidate] {
        Array(sortedByKeepPriority(group.photos).dropFirst())
    }

    private func sortedByKeepPriority(_ photos: [SimilarPhotoCandidate]) -> [SimilarPhotoCandidate] {
        photos.sorted { lhs, rhs in
            if lhs.createdDate != rhs.createdDate {
                return lhs.createdDate < rhs.createdDate
            }
            if lhs.size != rhs.size {
                return lhs.size > rhs.size
            }
            return lhs.path.path < rhs.path.path
        }
    }
}
