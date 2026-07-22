import Foundation
import Testing
@testable import MacSweepCore

struct AIAnalysisModelsTests {
    @Test func cacheCategoriesKeepTheirStableDisplayContracts() {
        let expectedRawValues = [
            "Electron/Chromium",
            "Package Manager",
            "Dev Debug Logs",
            "AI Tool Cache",
            "Other"
        ]
        let expectedIcons = ["globe", "shippingbox", "doc.text", "brain", "folder"]

        #expect(CacheCategory.allCases.map(\.rawValue) == expectedRawValues)
        #expect(CacheCategory.allCases.map(\.icon) == expectedIcons)
        #expect(CacheCategory.allCases.map(\.id) == expectedRawValues)
    }

    @Test func scanSourcesKeepTheirSerializedLabels() {
        #expect(ScanSource.deterministic.rawValue == "Fast Scan")
        #expect(ScanSource.ai.rawValue == "AI Analysis")
    }

    @Test func cacheFindingDefaultsToSelectedWithoutAReason() {
        let finding = CacheFinding(
            path: "/tmp/cache",
            size: "12 MB",
            category: .other,
            regeneratesAutomatically: true,
            source: .deterministic
        )

        #expect(finding.isSelected)
        #expect(finding.reason == nil)
    }

    @Test func cacheFindingCodableRoundTripPreservesEveryField() throws {
        var finding = CacheFinding(
            path: "/Users/example/Library/Caches/tool",
            size: "48 MB",
            category: .aiToolCache,
            regeneratesAutomatically: false,
            source: .ai,
            reason: "Unused cache reported by the local provider"
        )
        finding.isSelected = false

        let decoded = try JSONDecoder().decode(
            CacheFinding.self,
            from: JSONEncoder().encode(finding)
        )

        #expect(decoded.id == finding.id)
        #expect(decoded.path == finding.path)
        #expect(decoded.size == finding.size)
        #expect(decoded.category.rawValue == finding.category.rawValue)
        #expect(decoded.regeneratesAutomatically == finding.regeneratesAutomatically)
        #expect(decoded.source.rawValue == finding.source.rawValue)
        #expect(decoded.reason == finding.reason)
        #expect(decoded.isSelected == finding.isSelected)
    }
}
