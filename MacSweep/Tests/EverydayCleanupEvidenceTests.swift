import Foundation
import Testing

@testable import MacSweepCore

struct EverydayCleanupEvidenceTests {
    @Test(arguments: ["system-cache", "trash-bins"])
    func exactPathSizeAndHonestModificationEvidence(module: String) {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let path =
            module == "trash-bins"
            ? "/Users/fixture/.Trash/important.txt"
            : "/Users/fixture/Library/Caches/vendor/long nested cache/session.db"
        let item = CleanupItem(
            id: UUID(), path: URL(fileURLWithPath: path), size: 4_096,
            type: .file, module: module, moduleName: "Fixture", lastModified: date)
        let reason =
            module == "trash-bins" ? TrashBinsModule.cleanupReviewReason : SystemCacheModule.cleanupReviewReason
        let evidence = CleanupResultEvidence(
            item: item, modificationDate: item.lastModified,
            defaultReviewReason: reason)
        #expect(evidence.path == path)
        #expect(evidence.formattedSize == item.formattedSize)
        #expect(evidence.modification == .date(date))
        #expect(evidence.reviewReason.contains("permanently"))
        #expect(!evidence.reviewReason.contains("Deleted"))
        if module == "trash-bins" { #expect(evidence.reviewReason.contains("Put Back")) }
    }

    @Test func missingDateIsExplicitAndCustomReviewReasonWins() {
        let item = CleanupItem(
            id: UUID(), path: URL(fileURLWithPath: "/tmp/metadata-unavailable"), size: 10,
            type: .file, module: "system-cache", moduleName: "Fixture", cleanupReviewReason: "Review this cache first")
        let evidence = CleanupResultEvidence(
            item: item, modificationDate: nil,
            defaultReviewReason: SystemCacheModule.cleanupReviewReason)
        #expect(evidence.modification == .unavailable)
        #expect(evidence.reviewReason == "Review this cache first")
    }
}
