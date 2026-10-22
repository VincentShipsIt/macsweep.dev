import Foundation
import Testing

@testable import MacSweepCore

struct DeveloperCleanupOwnershipTests {
    @Test func genericNamesCannotAuthorizePersistentDeveloperState() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let checker = SafetyChecker(userRules: .empty)
        for relative in [
            ".lima/default/Cache", ".colima/default/target", ".pyenv/versions/3.10/build",
            "Library/Developer/Xcode/iOS DeviceSupport/old/Cache",
            "Library/Application Support/Claude/vm_bundles/warm/Cache",
            "Documents/Unusual Location/example.utm/Cache", "Parallels/example.pvm/build"
        ] {
            let path = home.appending(path: relative)
            #expect(!checker.validateForCleanup(path, moduleID: "ai-analysis").isSafe)
            #expect(!checker.validateForCleanup(path, moduleID: "large-files").isSafe)
            #expect(!checker.validateForTrash(path).isSafe)
            #expect(!checker.validateForShred(path).isSafe)
        }
    }

    @Test func ownerAuthorityDoesNotAuthorizeAnotherDomainOrOverrideUserRules() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lima = home.appending(path: ".lima/default/Cache")
        let checker = SafetyChecker(userRules: .empty)
        #expect(!checker.validateForTrash(lima, developerOwner: .xcode).isSafe)
        #expect(checker.validateForTrash(lima, developerOwner: .virtualMachines).isSafe)
        let rules = UserProtectionRules(ignoreContents: "", protectContents: lima.path, homeURL: home)
        #expect(!SafetyChecker(userRules: rules).validateForTrash(lima, developerOwner: .virtualMachines).isSafe)
    }

    @Test func analyzerNeverSuggestsVmDownloadOrNestedCacheAsRegenerableJunk() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/vm_bundles/warm/Cache")
        #expect(CacheAnalyzer.parseFastScanOutput("20\t\(path.path)").isEmpty)
    }
}
