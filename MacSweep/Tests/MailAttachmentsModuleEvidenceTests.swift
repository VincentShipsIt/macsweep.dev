import Foundation
import Testing
@testable import MacSweepCore

struct MailAttachmentsModuleEvidenceTests {
    @Test func presentationEvidencePreservesMetadataAndSuppliesFallbacks() {
        let expectedDate = Date(timeIntervalSince1970: 1_730_000_000)
        let dated = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/Users/example/Library/Mail Downloads/report.pdf"),
            size: 2048,
            type: .file,
            module: "mail-attachments",
            moduleName: "Apple Mail - Documents",
            lastModified: expectedDate
        )
        let missingMetadata = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/Users/example/Library/Mail Downloads/archive.zip"),
            size: 4096,
            type: .file,
            module: "mail-attachments",
            moduleName: "Apple Mail - Archives"
        )

        let datedEvidence = MailAttachmentEvidence(item: dated)
        let fallbackEvidence = MailAttachmentEvidence(item: missingMetadata)

        #expect(datedEvidence.path == dated.path.path)
        #expect(datedEvidence.formattedSize == dated.formattedSize)
        #expect(datedEvidence.modification == .date(expectedDate))
        #expect(datedEvidence.reviewReason == MailAttachmentsModule.cleanupReviewReason)
        #expect(fallbackEvidence.path == missingMetadata.path.path)
        #expect(fallbackEvidence.formattedSize == missingMetadata.formattedSize)
        #expect(fallbackEvidence.modification == .unavailable)
        #expect(fallbackEvidence.reviewReason == MailAttachmentsModule.cleanupReviewReason)
    }
}
