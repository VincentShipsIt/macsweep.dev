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
                    recommended: false,
                    reviewReason: "Protected by ~/.macsweepprotect rule: ~/www"
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
        #expect(json.contains("\"recommended\":false"))
        let decoded = try JSONDecoder().decode(HeadlessScanResult.self, from: data)
        #expect(decoded.findings.first?.reviewReason == "Protected by ~/.macsweepprotect rule: ~/www")
    }

    @Test func findingDecodesLegacyJSONWithoutReviewReason() throws {
        let legacy = """
        {
            "id": "finding-1",
            "module": "system-cache",
            "moduleName": "System Caches",
            "path": "/tmp/cache",
            "size": 1024,
            "type": "file",
            "recommended": true
        }
        """

        let finding = try JSONDecoder().decode(HeadlessFinding.self, from: Data(legacy.utf8))

        #expect(finding.reviewReason == nil)
        #expect(finding.recommended)
    }

    // MARK: - HeadlessThreatFinding (#98)

    @Test func threatFindingEncodesIdAndKnownSignature() throws {
        let finding = HeadlessThreatFinding(
            id: "D8B0BFCB-08B0-4B39-BB0A-2B0C5D1B2E77",
            path: "/Library/LaunchAgents/com.evil.plist",
            category: "Launch Agents",
            threatLevel: "malicious",
            description: "Matches known signature",
            aiExplanation: nil,
            remediation: nil,
            isKnownSignature: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(finding), as: UTF8.self)

        #expect(json.contains("\"id\":\"D8B0BFCB-08B0-4B39-BB0A-2B0C5D1B2E77\""))
        #expect(json.contains("\"isKnownSignature\":true"))
    }

    @Test func threatFindingRoundTrips() throws {
        let finding = HeadlessThreatFinding(
            id: "D8B0BFCB-08B0-4B39-BB0A-2B0C5D1B2E77",
            path: "/Library/LaunchAgents/com.evil.plist",
            category: "Launch Agents",
            threatLevel: "review",
            description: "Unsigned helper",
            aiExplanation: "explanation",
            remediation: "remove it",
            isKnownSignature: false
        )

        let data = try JSONEncoder().encode(finding)
        let decoded = try JSONDecoder().decode(HeadlessThreatFinding.self, from: data)

        #expect(decoded.id == finding.id)
        #expect(decoded.isKnownSignature == finding.isKnownSignature)
        #expect(decoded.path == finding.path)
    }

    @Test func threatFindingDecodesLegacyJSONWithoutNewFields() throws {
        // JSON emitted before `id`/`isKnownSignature` existed must still decode.
        let legacy = """
        {
            "path": "/Library/LaunchAgents/com.evil.plist",
            "category": "Launch Agents",
            "threatLevel": "suspicious",
            "description": "Old-format finding"
        }
        """
        let decoded = try JSONDecoder().decode(
            HeadlessThreatFinding.self,
            from: Data(legacy.utf8)
        )

        #expect(decoded.id.isEmpty)
        #expect(decoded.isKnownSignature == false)
        #expect(decoded.path == "/Library/LaunchAgents/com.evil.plist")
    }

    // MARK: - HeadlessCacheFinding (#99)

    @Test func cacheFindingEncodesRawByteCount() throws {
        let finding = HeadlessCacheFinding(
            path: "/Users/x/.npm/_cacache",
            sizeBytes: 1_288_490_189,
            sizeText: "1.29 GB",
            category: "Package Manager",
            regeneratesAutomatically: true,
            source: "Fast Scan",
            reason: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(finding), as: UTF8.self)

        #expect(json.contains("\"sizeBytes\":1288490189"))
        #expect(json.contains("\"sizeText\":\"1.29 GB\""))
    }

    @Test func cacheFindingDecodesLegacyJSONWithoutSizeBytes() throws {
        // JSON emitted before `sizeBytes` existed must still decode.
        let legacy = """
        {
            "path": "/Users/x/.npm/_cacache",
            "sizeText": "1.2G",
            "category": "Package Manager",
            "regeneratesAutomatically": true,
            "source": "Fast Scan"
        }
        """
        let decoded = try JSONDecoder().decode(
            HeadlessCacheFinding.self,
            from: Data(legacy.utf8)
        )

        #expect(decoded.sizeBytes == nil)
        #expect(decoded.sizeText == "1.2G")
    }
}
