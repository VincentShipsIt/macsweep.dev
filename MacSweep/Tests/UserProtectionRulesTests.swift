import Foundation
import Testing
@testable import MacSweepCore

struct UserProtectionRulesTests {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private func checker(ignore: String = "", protect: String = "") -> SafetyChecker {
        SafetyChecker(userRules: UserProtectionRules(
            ignoreContents: ignore,
            protectContents: protect,
            homeURL: home
        ))
    }

    @Test func ignoreRuleOmitsScanAndBlocksCleanup() {
        let checker = checker(ignore: "~/Downloads/private\n")
        let path = home.appending(path: "Downloads/private/archive.zip")

        let scan = checker.validateForScan(path, moduleID: "large-files")
        let cleanup = checker.validateForCleanup(path, moduleID: "large-files")

        #expect(!scan.isSafe)
        #expect(scan.reason?.contains(UserProtectionRules.ignoreFilename) == true)
        #expect(!cleanup.isSafe)
    }

    @Test func protectRuleStaysVisibleButCannotBeCleaned() {
        let checker = checker(protect: "~/www\n")
        let path = home.appending(path: "www/project/node_modules/cache.bin")

        #expect(checker.validateForScan(path, moduleID: "large-files").isSafe)
        let cleanup = checker.validateForCleanup(path, moduleID: "large-files")
        #expect(!cleanup.isSafe)
        #expect(cleanup.reason?.contains(UserProtectionRules.protectFilename) == true)
    }

    @Test func lastMatchingExceptionAllowsGeneratedArtifacts() {
        let checker = checker(protect: """
        ~/www
        !~/www/**/node_modules/**
        """)
        let artifactRoot = home.appending(path: "www/project/node_modules")
        let artifact = home.appending(path: "www/project/node_modules/pkg/cache.js")
        let source = home.appending(path: "www/project/Sources/App.swift")

        #expect(checker.validateForCleanup(artifactRoot, moduleID: "large-files").isSafe)
        #expect(checker.validateForCleanup(artifact, moduleID: "large-files").isSafe)
        #expect(!checker.validateForCleanup(source, moduleID: "large-files").isSafe)
    }

    @Test func globMatchesOneComponentWhileDoubleStarMatchesDepth() {
        let checker = checker(ignore: "~/www/*/coverage/**\n")
        let direct = home.appending(path: "www/app/coverage/unit/report.json")
        let nested = home.appending(path: "www/team/app/coverage/build/report.json")

        #expect(!checker.validateForScan(direct, moduleID: "large-files").isSafe)
        #expect(checker.validateForScan(nested, moduleID: "large-files").isSafe)
    }

    @Test func userExceptionCannotOverrideBuiltInProtection() {
        let checker = checker(protect: """
        ~/Documents
        !~/Documents/**
        """)
        let document = home.appending(path: "Documents/contract.pdf")

        #expect(!checker.validateForCleanup(document, moduleID: "large-files").isSafe)
    }

    @Test func loadsBothRuleFilesFromTheSharedHomeDirectory() throws {
        let temp = try TempTestDirectory(prefix: "MacSweepUserRulesTests")
        try "ignored\n".write(
            to: temp.url.appending(path: UserProtectionRules.ignoreFilename),
            atomically: true,
            encoding: .utf8
        )
        try "protected\n".write(
            to: temp.url.appending(path: UserProtectionRules.protectFilename),
            atomically: true,
            encoding: .utf8
        )

        let rules = UserProtectionRules.load(homeURL: temp.url)

        #expect(rules.decision(for: temp.url.appending(path: "ignored/file").path)
            == .ignored(pattern: "ignored"))
        #expect(rules.decision(for: temp.url.appending(path: "protected/file").path)
            == .protected(pattern: "protected"))
    }
}
