import Foundation
import Testing
@testable import MacSweepCore

final class PrivacyModuleEvidenceTests {
    private let temp: TempTestDirectory
    private let root: URL

    init() throws {
        temp = try TempTestDirectory(prefix: "MacSweepPrivacyEvidenceTests")
        root = temp.url
    }

    @Test func fileAndDirectoryFindingsCarryModificationEvidenceAndReviewReason() throws {
        let file = root.appendingPathComponent("Downloads.plist")
        let directory = root.appendingPathComponent("Example.savedState")
        try Data("privacy fixture".utf8).write(to: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileDate = Date(timeIntervalSince1970: 1_700_000_000)
        let directoryDate = Date(timeIntervalSince1970: 1_710_000_000)
        try FileManager.default.setAttributes([.modificationDate: fileDate], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: directoryDate], ofItemAtPath: directory.path)

        let module = PrivacyModule()
        let fileItem = module.makeCleanupItem(
            at: file,
            size: 15,
            type: .file,
            moduleName: "Safari Downloads History"
        )
        let directoryItem = module.makeCleanupItem(
            at: directory,
            size: 4096,
            type: .directory,
            moduleName: "Saved State - Example"
        )

        let fileModified = try #require(fileItem.lastModified)
        let directoryModified = try #require(directoryItem.lastModified)
        #expect(abs(fileModified.timeIntervalSince(fileDate)) < 1)
        #expect(abs(directoryModified.timeIntervalSince(directoryDate)) < 1)
        #expect(fileItem.cleanupReviewReason == PrivacyModule.cleanupReviewReason)
        #expect(directoryItem.cleanupReviewReason == PrivacyModule.cleanupReviewReason)
    }

    @Test func presentationEvidencePreservesMetadataAndSuppliesFallbacks() {
        let expectedDate = Date(timeIntervalSince1970: 1_720_000_000)
        let dated = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/Users/example/Library/Safari/Downloads.plist"),
            size: 2048,
            type: .file,
            module: "privacy",
            moduleName: "Safari Downloads History",
            lastModified: expectedDate,
            cleanupReviewReason: "Custom review reason"
        )
        let missingMetadata = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/Users/example/Library/RecentItems.sfl2"),
            size: 0,
            type: .file,
            module: "privacy",
            moduleName: "Recent Documents"
        )

        let datedEvidence = PrivacyItemEvidence(item: dated)
        let fallbackEvidence = PrivacyItemEvidence(item: missingMetadata)

        #expect(datedEvidence.path == dated.path.path)
        #expect(datedEvidence.formattedSize == dated.formattedSize)
        #expect(datedEvidence.modification == .date(expectedDate))
        #expect(datedEvidence.reviewReason == "Custom review reason")
        #expect(fallbackEvidence.modification == .unavailable)
        #expect(fallbackEvidence.reviewReason == PrivacyModule.cleanupReviewReason)
    }
}
