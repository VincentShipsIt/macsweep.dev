import XCTest
@testable import MacSweepCore

final class HeadlessSerializationTests: XCTestCase {
    func testScanResultEncodesStableJSONKeys() throws {
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

        XCTAssertTrue(json.contains("\"executedModules\""))
        XCTAssertTrue(json.contains("\"permissions\""))
        XCTAssertTrue(json.contains("\"findings\""))
        XCTAssertTrue(json.contains("\"summary\""))
        XCTAssertTrue(json.contains("\"recommended\":true"))
    }
}
