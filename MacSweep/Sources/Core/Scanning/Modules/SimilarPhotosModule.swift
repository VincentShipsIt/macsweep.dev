import Foundation
import AppKit
import CoreGraphics
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
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads"),
    ]

    var minimumFileSize: Int64 = 204_800
    var similarityThreshold: Int = 8
    var maxImages: Int = 250

    func scan() async throws -> [CleanupItem] {
        let candidates = try await imageCandidates()
        let groups = SimilarPhotoGrouper(threshold: similarityThreshold).group(candidates)
        let selector = SimilarPhotoSelector()

        return groups.flatMap { group in
            selector.autoSelect(group).map { photo in
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
        }
        .sorted { $0.size > $1.size }
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
            .creationDateKey,
        ]

        var candidates: [SimilarPhotoCandidate] = []

        for root in searchPaths where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: resourceKeys)
                guard values?.isDirectory == false, values?.isSymbolicLink == false else { continue }
                guard values?.contentType?.conforms(to: .image) == true else { continue }
                guard checker.validateForScan(url, moduleID: id).isSafe else { continue }

                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
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
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []
        let checker = SafetyChecker()

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
                continue
            }

            // Defense-in-depth: re-validate every item before deleting,
            // even though scan() already filtered to safe paths.
            guard checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Blocked by safety checks"
                ))
                continue
            }

            do {
                try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
                processed += 1
                freed += item.size
            } catch {
                errors.append(CleanupError(
                    path: item.path,
                    message: error.localizedDescription,
                    underlyingError: error
                ))
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

struct SimilarPhotoSignature: Hashable, Sendable {
    let bits: UInt64
    let aspectRatioBucket: Int

    static func make(from url: URL) -> SimilarPhotoSignature? {
        guard let sourceImage = NSImage(contentsOf: url) else { return nil }
        guard let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

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
    func autoSelect(_ group: SimilarPhotoGroup) -> [SimilarPhotoCandidate] {
        let sorted = group.photos.sorted { lhs, rhs in
            if lhs.createdDate != rhs.createdDate {
                return lhs.createdDate < rhs.createdDate
            }
            if lhs.size != rhs.size {
                return lhs.size > rhs.size
            }
            return lhs.path.path < rhs.path.path
        }

        return Array(sorted.dropFirst())
    }
}
