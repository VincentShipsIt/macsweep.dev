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

    private func app(id: String, name: String = "App") -> InstalledApp {
        InstalledApp(
            id: id,
            name: name,
            bundlePath: URL(fileURLWithPath: "/Applications/\(name).app"),
            version: nil,
            bundleSize: 0,
            icon: nil,
            lastUsed: nil
        )
    }

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
        let app = app(id: "com.foo.App")
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.foo.App.plist", bundleID: app.id, appName: app.name, installedApps: [app]))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.foo.App.plist", bundleID: app.id, appName: app.name, installedApps: [app], type: .preferences))
    }

    @Test func matchesBundleIDDottedPrefix() {
        // Saved-state / container / helper names carry the bundle id as a prefix.
        let app = app(id: "com.foo.App")
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.foo.App.savedState", bundleID: app.id, appName: app.name, installedApps: [app]))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.foo.App", bundleID: app.id, appName: app.name, installedApps: [app]))
    }

    @Test func matchesAppNameFolderIgnoringSpacesAndCase() {
        // An Application Support folder named after the app ("Google Chrome").
        let app = app(id: "com.google.Chrome", name: "Google Chrome")
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "Google Chrome", bundleID: app.id, appName: app.name, installedApps: [app]))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "Google Chrome.plist", bundleID: app.id, appName: app.name, installedApps: [app], type: .preferences))
    }

    @Test func rejectsDecoySubstringOfAppName() {
        // The core #76 regression: uninstalling "Mail" must NOT match "MailChimp"
        // data — the old two-way substring test destroyed it.
        let app = app(id: "com.apple.mail", name: "Mail")
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "MailChimp", bundleID: app.id, appName: app.name, installedApps: [app]))
    }

    @Test func rejectsUnrelatedBundleID() {
        let app = app(id: "com.foo.App")
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.other.Thing.plist", bundleID: app.id, appName: app.name, installedApps: [app]))
    }

    @Test func rejectsItemThatIsSubstringOfBundleID() {
        // The old reverse-substring branch (`term.contains(itemName)`) matched a
        // folder whose short name was a substring of the app name / bundle id.
        let app = app(id: "com.foo.App")
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com", bundleID: app.id, appName: app.name, installedApps: [app]))
    }

    @Test func rejectsEmptyBundleAndName() {
        // A fallback app with no usable identifiers must not match arbitrary items.
        let app = app(id: "", name: "")
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.someone.else", bundleID: app.id, appName: app.name, installedApps: [app]))
    }

    @Test func rejectsStableAppClaimOnInstalledCanaryOrBetaData() {
        let stable = app(id: "com.vendor.app", name: "Vendor App")
        let canary = app(id: "com.vendor.app.canary", name: "Vendor App Canary")
        let beta = app(id: "com.vendor.app.beta", name: "Vendor App Beta")
        let installed = [stable, canary, beta]

        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.canary.plist", bundleID: stable.id, appName: stable.name, installedApps: installed))
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.beta.savedState", bundleID: stable.id, appName: stable.name, installedApps: installed))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.canary.plist", bundleID: canary.id, appName: canary.name, installedApps: installed))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.beta.savedState", bundleID: beta.id, appName: beta.name, installedApps: installed))
    }

    @Test func resolvesPlistSuffixedBundleIDsByLocationWithoutCrossAppClaims() {
        let stable = app(id: "com.vendor.app", name: "Vendor App")
        let plistApp = app(id: "com.vendor.app.plist", name: "Vendor App Plist")
        let installed = [stable, plistApp]

        // Outside Preferences, `.plist` is part of the raw name and the exact,
        // longer installed ID owns it. The previous extension stripping let
        // `stable` claim this same item instead.
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.plist", bundleID: stable.id, appName: stable.name, installedApps: installed, type: .applicationSupport))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.plist", bundleID: plistApp.id, appName: plistApp.name, installedApps: installed, type: .applicationSupport))

        // In Preferences the raw bundle-ID and extension-stripped candidates
        // disagree, so neither app may claim potentially destructive data.
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.plist", bundleID: stable.id, appName: stable.name, installedApps: installed, type: .preferences))
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.plist", bundleID: plistApp.id, appName: plistApp.name, installedApps: installed, type: .preferences))
    }

    @Test func matchesUnambiguousHelperData() {
        let app = app(id: "com.vendor.app", name: "Vendor App")
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.helper.service.plist", bundleID: app.id, appName: app.name, installedApps: [app]))
    }

    @Test func normalizesCaseForExactBundleIDAndHelperData() {
        let app = app(id: "com.Vendor.App", name: "Vendor App")
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "COM.VENDOR.APP", bundleID: app.id, appName: app.name, installedApps: [app]))
        #expect(LeftoverScanner.leftoverMatches(
            itemName: "COM.VENDOR.APP.HELPER.PLIST", bundleID: app.id, appName: app.name, installedApps: [app]))
    }

    @Test func rejectsAmbiguousBundleIDOrAppNameOwnership() {
        let first = app(id: "com.vendor.app", name: "Vendor App")
        let duplicate = app(id: "com.vendor.app", name: "Vendor App Copy")
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "com.vendor.app.plist", bundleID: first.id, appName: first.name, installedApps: [first, duplicate]))

        let sameName = app(id: "com.other.app", name: "Vendor App")
        #expect(!LeftoverScanner.leftoverMatches(
            itemName: "Vendor App", bundleID: first.id, appName: first.name, installedApps: [first, sameName]))
    }

    // MARK: - Leftover removal gate (validateForUninstallLeftover)

    @Test func leftoverGateAllowsPreferencePlists() {
        // ~/Library/Preferences is in neverDelete, but preference plists are a
        // first-class leftover category — the dedicated gate must admit them
        // (the generic validateForTrash blocklist refuses them, which silently
        // broke uninstall cleanup).
        let plist = home.appending(path: "Library/Preferences/com.foo.App.plist")
        #expect(checker.validateForUninstallLeftover(plist).isSafe)
    }

    @Test func leftoverGateAllowsEveryScannedRoot() {
        let categories = [
            "Application Support/FooApp",
            "Caches/com.foo.App",
            "Logs/FooApp",
            "Containers/com.foo.App",
            "Saved Application State/com.foo.App.savedState",
            "LaunchAgents/com.foo.App.agent.plist",
        ]
        for relative in categories {
            let leftover = home.appending(path: "Library/\(relative)")
            #expect(checker.validateForUninstallLeftover(leftover).isSafe, "\(relative) must be removable")
        }
    }

    @Test func leftoverGateBlocksTheRootsThemselves() {
        for root in ["Preferences", "Application Support", "Caches", "Containers", "LaunchAgents"] {
            let url = home.appending(path: "Library/\(root)")
            #expect(!checker.validateForUninstallLeftover(url).isSafe, "\(root) root itself must never be trashed")
        }
    }

    @Test func leftoverGateBlocksPathsOutsideScannedRoots() {
        // Keychains is NOT a leftover root — a fuzzy match there must be refused.
        #expect(!checker.validateForUninstallLeftover(
            home.appending(path: "Library/Keychains/com.foo.App.keychain-db")).isSafe)
        // Nested deeper than a root's direct children is not how the scanner
        // discovers leftovers — refuse.
        #expect(!checker.validateForUninstallLeftover(
            home.appending(path: "Library/Preferences/ByHost/com.foo.App.plist")).isSafe)
        // Entirely outside ~/Library.
        #expect(!checker.validateForUninstallLeftover(
            home.appending(path: "Documents/com.foo.App")).isSafe)
    }

    @Test func leftoverGateBlocksSensitiveFilenames() {
        // Even inside a scanned root, credential-looking names stay refused.
        #expect(!checker.validateForUninstallLeftover(
            home.appending(path: "Library/Application Support/credentials.json")).isSafe)
        #expect(!checker.validateForUninstallLeftover(
            home.appending(path: "Library/Preferences/com.foo.App.keychain")).isSafe)
    }
}
