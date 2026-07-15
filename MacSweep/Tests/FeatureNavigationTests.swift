import Testing
@testable import MacSweepCore

struct FeatureNavigationTests {
    @Test func visibleDestinationsHaveUniqueAccessibleMetadata() {
        let features = FeatureSection.allCases.flatMap(\.features)

        #expect(Set(features.map(\.rawValue)).count == features.count)
        #expect(features.allSatisfy { !$0.rawValue.isEmpty })
        #expect(features.allSatisfy { !$0.icon.isEmpty })
        #expect(features.allSatisfy { $0.section.features.contains($0) })
    }

    @Test func keyboardDestinationsLeadTheSidebar() {
        #expect(FeatureSection.main.features == [.smartScan, .assistant, .cleanupHistory])
    }

    @Test func developerLogsStayInTheirGatedSection() {
        #expect(FeatureSection.developer.features == [.developerLogs])
        #expect(Feature.developerLogs.section == .developer)
    }
}
