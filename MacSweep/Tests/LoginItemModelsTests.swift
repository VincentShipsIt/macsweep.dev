import Foundation
import Testing
@testable import MacSweepCore

struct LoginItemModelsTests {
    @Test func loginItemTypeRawValuesStayStable() {
        #expect(LoginItemType.allCases == [.appService, .launchAgent, .launchDaemon])
        #expect(LoginItemType.allCases.map(\.rawValue) == ["App", "Launch Agent", "Launch Daemon"])
    }

    @Test func riskLevelRawValuesStayStable() {
        #expect(RiskLevel.safe.rawValue == "safe")
        #expect(RiskLevel.suspicious.rawValue == "suspicious")
        #expect(RiskLevel.unknown.rawValue == "unknown")
    }

    @Test func plistPathDefaultPreservesLegacyCallSites() {
        let item = LoginItem(
            id: UUID(),
            name: "Example Agent",
            path: "/Library/LaunchAgents/dev.example.agent.plist",
            type: .launchAgent,
            bundleIdentifier: "dev.example.agent",
            isEnabled: true,
            aiAnalysis: nil
        )

        #expect(item.isEnabled)
        #expect(item.aiAnalysis == nil)
        #expect(item.plistPath == nil)
    }

    @Test func decodesLegacyPayloadWithoutPlistPath() throws {
        let legacy = """
        {
            "id": "A5C97834-E5F7-4F0A-AEC7-7243573B72D9",
            "name": "Legacy Agent",
            "path": "/Library/LaunchAgents/dev.example.legacy.plist",
            "type": "Launch Agent",
            "bundleIdentifier": "dev.example.legacy",
            "isEnabled": false,
            "aiAnalysis": null
        }
        """

        let item = try JSONDecoder().decode(LoginItem.self, from: Data(legacy.utf8))

        #expect(item.id.uuidString == "A5C97834-E5F7-4F0A-AEC7-7243573B72D9")
        #expect(item.type == .launchAgent)
        #expect(item.plistPath == nil)
    }

    @Test func roundTripsLoginItemWithAIAnalysis() throws {
        let id = try #require(UUID(uuidString: "9243B55D-A7CA-4291-BDB8-810007A6E974"))
        let item = LoginItem(
            id: id,
            name: "Example Helper",
            path: "/Library/LaunchDaemons/dev.example.helper.plist",
            type: .launchDaemon,
            bundleIdentifier: "dev.example.helper",
            isEnabled: false,
            aiAnalysis: AIItemAnalysis(
                summary: "Runs a background helper",
                riskLevel: .suspicious,
                recommendation: "Consider disabling",
                lastSeenDaysAgo: 14
            ),
            plistPath: "/Library/LaunchDaemons/example-helper.plist"
        )

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(LoginItem.self, from: data)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let analysis = try #require(json["aiAnalysis"] as? [String: Any])

        #expect(decoded.id == item.id)
        #expect(decoded.name == item.name)
        #expect(decoded.path == item.path)
        #expect(decoded.type == item.type)
        #expect(decoded.bundleIdentifier == item.bundleIdentifier)
        #expect(decoded.isEnabled == item.isEnabled)
        #expect(decoded.aiAnalysis?.summary == item.aiAnalysis?.summary)
        #expect(decoded.aiAnalysis?.riskLevel == item.aiAnalysis?.riskLevel)
        #expect(decoded.aiAnalysis?.recommendation == item.aiAnalysis?.recommendation)
        #expect(decoded.aiAnalysis?.lastSeenDaysAgo == item.aiAnalysis?.lastSeenDaysAgo)
        #expect(decoded.plistPath == item.plistPath)
        #expect(Set(json.keys) == [
            "aiAnalysis", "bundleIdentifier", "id", "isEnabled",
            "name", "path", "plistPath", "type"
        ])
        #expect(Set(analysis.keys) == [
            "lastSeenDaysAgo", "recommendation", "riskLevel", "summary"
        ])
    }
}
