import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for the two deletion-safety fixes in the app uninstaller:
///   • #81 — the `.app` bundle removal is now gated by
///     `SafetyChecker.validateForAppBundleRemoval`.
///   • #76 — leftover matching is tightened from a loose two-way substring test
///     to bundle-id (exact / dotted-prefix) plus an exact app-name compare.
struct AppUninstallerModuleTests {
    private let checker = SafetyChecker()
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - Bundle removal gate (#81)

    @Test func allowsAppBundleInSystemApplications() {
        let app = URL(fileURLWithPath: "/Applications/Some Thing.app")
        #expect(checker.validateForAppBundleRemoval(app).isSafe)
    }

    @Test func allowsAppBundleInUserApplications() {
        let app = home.appending(path: "Applications/Tool.app")
        #expect(checker.validateForAppBundleRemoval(app).isSafe)
    }

    @Test func blocksNonBundlePath() {
        // A stray non-.app path in /Applications must not be treated as a bundle.
        let notApp = URL(fileURLWithPath: "/Applications/config.plist")
        #expect(!checker.validateForAppBundleRemoval(notApp).isSafe)
    }

    @Test func blocksBundleOutsideApplicationsRoots() {
        // An .app the user dragged into Downloads is outside the known install
        // roots — the gate refuses to trash from there via the uninstaller.
        let app = home.appending(path: "Downloads/Sneaky.app")
        #expect(!checker.validateForAppBundleRemoval(app).isSafe)
    }

    @Test func blocksBundleNestedBelowApplicationsRoot() {
        // Must sit DIRECTLY in the root; a bundle one level down is not a
        // top-level install and must not satisfy the gate.
        let app = URL(fileURLWithPath: "/Applications/Utilities/Nested.app")
        #expect(!checker.validateForAppBundleRemoval(app).isSafe)
    }

    // MARK: - Leftover matching (#76)

    @Test func matchesExactBundleIDPlist() {
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.foo.App.plist", bundleID: "com.foo.App", appName: "App"))
    }

    @Test func matchesBundleIDDottedPrefix() {
        // Saved-state / container / helper names carry the bundle id as a prefix.
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.foo.App.savedState", bundleID: "com.foo.App", appName: "App"))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.foo.App", bundleID: "com.foo.App", appName: "App"))
    }

    @Test func matchesAppNameFolderIgnoringSpacesAndCase() {
        // An Application Support folder named after the app ("Google Chrome").
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "Google Chrome", bundleID: "com.google.Chrome", appName: "Google Chrome"))
    }

    @Test func rejectsDecoySubstringOfAppName() {
        // The core #76 regression: uninstalling "Mail" must NOT match "MailChimp"
        // data — the old two-way substring test destroyed it.
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "MailChimp", bundleID: "com.apple.mail", appName: "Mail"))
    }

    @Test func rejectsUnrelatedBundleID() {
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.other.Thing.plist", bundleID: "com.foo.App", appName: "App"))
    }

    @Test func rejectsItemThatIsSubstringOfBundleID() {
        // The old reverse-substring branch (`term.contains(itemName)`) matched a
        // folder whose short name was a substring of the app name / bundle id.
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com", bundleID: "com.foo.App", appName: "App"))
    }

    @Test func rejectsEmptyBundleAndName() {
        // A fallback app with no usable identifiers must not match arbitrary items.
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.someone.else", bundleID: "", appName: ""))
    }
}
