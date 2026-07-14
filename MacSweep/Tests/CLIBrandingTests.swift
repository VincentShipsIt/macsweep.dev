import Foundation
import Testing
import MacSweepCore
@testable import MacSweepCLIKit

struct CLIBrandingTests {
    @Test func rendersVersionWithProductBrand() {
        let output = CLIVersionOutput(
            metadata: CLICommandMetadata(command: "version", timestamp: Date(), executedModules: []),
            version: "1.2.3"
        )

        #expect(CLIExecutor.renderText(output) == "macsweep.dev 1.2.3")
    }

    @Test func rendersProtectionReasonForReviewOnlyFinding() {
        let reason = "Protected by ~/.macsweepprotect rule: ~/www"
        let output = CLIScanOutput(
            metadata: CLICommandMetadata(command: "scan", timestamp: Date(), executedModules: ["large-files"]),
            permissions: HeadlessPermissionStatusReport(fullDiskAccessGranted: true, modules: []),
            findings: [
                HeadlessFinding(
                    id: UUID().uuidString,
                    module: "large-files",
                    moduleName: "Folder",
                    path: "/Users/tester/www",
                    size: 1_024,
                    type: "directory",
                    lastModified: nil,
                    recommended: false,
                    reviewReason: reason
                )
            ],
            summary: HeadlessSummary(
                score: 90,
                reclaimableBytes: 1_024,
                totalFindings: 1,
                issueCount: 1,
                categoryCount: 1,
                recommendedFindings: 0,
                recommendedBytes: 0,
                errors: []
            ),
            cleanup: nil
        )

        #expect(CLIExecutor.renderText(output).contains("review-only: \(reason)"))
    }
}
