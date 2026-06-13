import Testing
import Foundation
@testable import MacSweepCore

struct HeadlessSerializationTests {
    @Test func scanResultEncodesStableJSONKeys() throws {
        let result = HeadlessScanResult(
            executedModules: ["system-cache"],
            permissions: HeadlessPermissionStatusReport(
                fullDiskAccessGranted: true,
                modules: [
                    HeadlessModulePermissionStatus(
                        moduleID: "system-cache",
                        moduleName: "System Caches",
                        requirements: [],
                        allRequirementsSatisfied: true
                    )
                ]
            ),
            findings: [
                HeadlessFinding(
                    id: UUID().uuidString,
                    module: "system-cache",
                    moduleName: "System Caches",
                    path: "/tmp/cache",
                    size: 1024,
                    type: "file",
                    lastModified: nil,
                    recommended: true
                )
            ],
            summary: HeadlessSummary(
                score: 88,
                reclaimableBytes: 1024,
                totalFindings: 1,
                issueCount: 1,
                categoryCount: 1,
                recommendedFindings: 1,
                recommendedBytes: 1024,
                errors: []
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("\"executedModules\""))
        #expect(json.contains("\"permissions\""))
        #expect(json.contains("\"findings\""))
        #expect(json.contains("\"summary\""))
        #expect(json.contains("\"recommended\":true"))
    }
}
