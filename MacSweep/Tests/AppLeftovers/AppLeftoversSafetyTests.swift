import Foundation
import Testing

@testable import MacSweepCore

struct AppLeftoversSafetyTests {
    @Test func scopedTreeGateAdmitsDeepContentButRejectsEscapesCredentialsAndRules() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "leftover-safety-\(UUID())")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appending(path: "Library")
        let target = library.appending(path: "Containers/org.fixture.gone")
        try FileManager.default.createDirectory(
            at: target.appending(path: "Data/nested"), withIntermediateDirectories: true)
        let checker = SafetyChecker(
            userRules: UserProtectionRules(ignoreContents: "", protectContents: "", homeURL: root))
        #expect(checker.validateForUninstallLeftoverTreeNode(target, within: target, libraryDirectory: library).isSafe)
        #expect(
            checker.validateForUninstallLeftoverTreeNode(
                target.appending(path: "Data/nested/value"), within: target, libraryDirectory: library
            ).isSafe)
        #expect(
            !checker.validateForUninstallLeftoverTreeNode(library, within: target, libraryDirectory: library).isSafe)
        #expect(
            !checker.validateForUninstallLeftoverTreeNode(
                target.appending(path: "../org.fixture.other"), within: target, libraryDirectory: library
            ).isSafe)
        #expect(
            !checker.validateForUninstallLeftoverTreeNode(
                target.appending(path: "Data/id_rsa/value"), within: target, libraryDirectory: library
            ).isSafe)
        let protected = SafetyChecker(
            userRules: UserProtectionRules(
                ignoreContents: "", protectContents: target.appending(path: "Data").path + "\n", homeURL: root))
        #expect(
            !protected.validateForUninstallLeftoverTreeNode(
                target.appending(path: "Data/nested"), within: target, libraryDirectory: library
            ).isSafe)
        try FileManager.default.createSymbolicLink(at: target.appending(path: "alias"), withDestinationURL: root)
        #expect(
            !checker.validateForUninstallLeftoverTreeNode(
                target.appending(path: "alias"), within: target, libraryDirectory: library
            ).isSafe)
        #expect(
            !checker.validateForUninstallLeftoverTreeNode(
                target.appending(path: "alias/Library"), within: target, libraryDirectory: library
            ).isSafe)
        for category in ["Group Containers", "Application Scripts"] {
            let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library").appending(
                path: category
            ).appending(path: "org.fixture.gone")
            #expect(checker.validateForUninstallLeftover(path).isSafe)
            #expect(!checker.validateForCleanup(path).isSafe)
            #expect(!checker.validateForUninstallLeftover(path.deletingLastPathComponent()).isSafe)
        }
    }
}
