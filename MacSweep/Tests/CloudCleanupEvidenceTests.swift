import Foundation
import Testing
@testable import MacSweepCore

struct CloudCleanupEvidenceTests {
    @Test func localCopyEvidencePreservesMetadataAndExplainsEviction() {
        let expectedDate = Date(timeIntervalSince1970: 1_730_000_000)
        let item = cleanupItem(
            path: "/Users/example/Library/Mobile Documents/report.pdf",
            moduleName: "iCloud Local Copy",
            lastModified: expectedDate
        )

        let evidence = CloudCleanupEvidence(item: item)

        #expect(evidence.path == item.path.path)
        #expect(evidence.formattedSize == item.formattedSize)
        #expect(evidence.modification == .date(expectedDate))
        #expect(evidence.reviewReason == CloudCleanupModule.localCopyReviewReason)
    }

    @Test func providerCacheEvidenceSuppliesMissingDateFallbackAndCacheRationale() {
        let item = cleanupItem(
            path: "/Users/example/Library/Caches/Dropbox",
            moduleName: "Dropbox Cache"
        )

        let evidence = CloudCleanupEvidence(item: item)

        #expect(evidence.path == item.path.path)
        #expect(evidence.formattedSize == item.formattedSize)
        #expect(evidence.modification == .unavailable)
        #expect(evidence.reviewReason == CloudCleanupModule.providerCacheReviewReason)
    }

    @Test func customReviewReasonOverridesTheActionFallback() {
        let item = cleanupItem(
            path: "/Users/example/Library/Caches/CloudKit",
            moduleName: "iCloud Cache",
            cleanupReviewReason: "Review this cache before reclaiming it."
        )

        let evidence = CloudCleanupEvidence(item: item)

        #expect(evidence.reviewReason == "Review this cache before reclaiming it.")
    }

    private func cleanupItem(
        path: String,
        moduleName: String,
        lastModified: Date? = nil,
        cleanupReviewReason: String? = nil
    ) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: path),
            size: 8_400_000,
            type: moduleName.contains("Local Copy") ? .file : .directory,
            module: "cloud-cleanup",
            moduleName: moduleName,
            lastModified: lastModified,
            cleanupReviewReason: cleanupReviewReason
        )
    }
}
