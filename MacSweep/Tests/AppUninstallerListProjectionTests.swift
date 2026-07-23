import Foundation
import Testing
@testable import MacSweepCore

@Suite("App Uninstaller list projection")
struct AppUninstallerListProjectionTests {
    @Test func preservesSortOptionLabelsAndOrder() {
        #expect(AppUninstallerSortOrder.allCases == [.name, .size, .lastUsed])
        #expect(AppUninstallerSortOrder.allCases.map(\.rawValue) == ["Name", "Size", "Last Used"])
    }

    @Test func searchesNamesAndBundleIdentifiersCaseInsensitively() {
        let apps = [
            app(id: "com.example.alpha", name: "Alpha Editor"),
            app(id: "com.example.beta", name: "Beta Browser"),
            app(id: "dev.tools.gamma", name: "Gamma Tool")
        ]

        #expect(apps.appList(matching: "ALPHA", sortedBy: .name).map(\.id) == ["com.example.alpha"])
        #expect(apps.appList(matching: "EXAMPLE.BETA", sortedBy: .name).map(\.id) == ["com.example.beta"])
    }

    @Test func sortsNamesAscendingUsingTheExistingLocalizedComparison() {
        let apps = [
            app(id: "com.example.zulu", name: "Zulu"),
            app(id: "com.example.alpha", name: "Alpha"),
            app(id: "com.example.delta", name: "Delta")
        ]

        #expect(apps.appList(matching: "", sortedBy: .name).map(\.name) == ["Alpha", "Delta", "Zulu"])
    }

    @Test func sortsByTotalSizeDescendingIncludingLeftovers() {
        let apps = [
            app(id: "small", name: "Small", bundleSize: 100),
            app(id: "largest", name: "Largest", bundleSize: 200, leftoverSize: 400),
            app(id: "middle", name: "Middle", bundleSize: 300)
        ]

        #expect(apps.appList(matching: "", sortedBy: .size).map(\.id) == ["largest", "middle", "small"])
    }

    @Test func sortsNewestFirstAndPlacesMissingLastUsedDatesLast() {
        let oldest = Date(timeIntervalSince1970: 100)
        let newest = Date(timeIntervalSince1970: 300)
        let apps = [
            app(id: "missing", name: "Missing", lastUsed: nil),
            app(id: "oldest", name: "Oldest", lastUsed: oldest),
            app(id: "newest", name: "Newest", lastUsed: newest)
        ]

        #expect(apps.appList(matching: "", sortedBy: .lastUsed).map(\.id) == ["newest", "oldest", "missing"])
    }

    @Test func returnsAnEmptyResultWhenNoAppMatches() {
        let apps = [app(id: "com.example.editor", name: "Editor")]

        #expect(apps.appList(matching: "browser", sortedBy: .name).isEmpty)
        #expect([InstalledApp]().appList(matching: "", sortedBy: .name).isEmpty)
    }

    private func app(
        id: String,
        name: String,
        bundleSize: Int64 = 0,
        leftoverSize: Int64 = 0,
        lastUsed: Date? = nil
    ) -> InstalledApp {
        var installedApp = InstalledApp(
            id: id,
            name: name,
            bundlePath: URL(fileURLWithPath: "/Applications/\(name).app"),
            version: nil,
            bundleSize: bundleSize,
            icon: nil,
            lastUsed: lastUsed
        )

        if leftoverSize > 0 {
            installedApp.leftovers = [
                AppLeftover(
                    id: UUID(),
                    path: URL(fileURLWithPath: "/tmp/\(id)"),
                    size: leftoverSize,
                    type: .caches
                )
            ]
        }

        return installedApp
    }
}
