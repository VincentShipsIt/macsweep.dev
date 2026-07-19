import Foundation
import Testing
@testable import MacSweepCore

struct UserProtectionRulesTests {
    private struct InjectedWriteFailure: LocalizedError {
        var errorDescription: String? { "Injected write failure" }
    }

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

    @Test func editableDocumentPreservesCommentsAndBlankLines() throws {
        let fileURL = home.appending(path: UserProtectionRules.protectFilename)
        var document = try UserProtectionRuleDocument(
            kind: .protect,
            fileURL: fileURL,
            contents: "# Keep source workspaces visible\n\n~/www\n!~/www/**/node_modules/**\n"
        )
        var entries = document.entries
        entries[0].pattern = "~/Projects"
        entries.removeLast()
        entries.append(.init(pattern: "~/Downloads/private"))

        try document.replaceEntries(entries)

        #expect(
            document.renderedContents
                == "# Keep source workspaces visible\n\n~/Projects\n~/Downloads/private\n"
        )
    }

    @Test func ruleValidationRejectsCommentsEmptyPathsAndMultipleLines() {
        let invalidPatterns = ["", "   ", "# not a rule", "!~/exception", "~/one\n~/two"]

        for pattern in invalidPatterns {
            let entry = UserProtectionRuleDocument.Entry(pattern: pattern)
            #expect(UserProtectionRuleDocument.validationMessage(for: entry) != nil)
        }

        let valid = UserProtectionRuleDocument.Entry(
            pattern: "~/www/**/node_modules/**",
            isException: true
        )
        #expect(UserProtectionRuleDocument.validationMessage(for: valid) == nil)
    }

    @Test func storeCreatesAndRoundTripsEachBackingFile() throws {
        let temp = try TempTestDirectory(prefix: "MacSweepUserRuleStoreTests")
        let store = UserProtectionRuleStore(homeURL: temp.url)
        var document = try store.load(.ignore)

        try document.replaceEntries([
            .init(pattern: "~/Downloads/private"),
            .init(pattern: "~/Downloads/private/keep", isException: true)
        ])
        try store.save(document)

        let reloaded = try store.load(.ignore)
        #expect(reloaded.fileURL == temp.url.appending(path: UserProtectionRules.ignoreFilename))
        #expect(reloaded.entries.map(\.pattern) == [
            "~/Downloads/private",
            "~/Downloads/private/keep"
        ])
        #expect(reloaded.entries.map(\.isException) == [false, true])
        #expect(try String(contentsOf: reloaded.fileURL, encoding: .utf8)
            == "~/Downloads/private\n!~/Downloads/private/keep")
    }

    @Test func failedAtomicSaveKeepsDiskContentAndEditedDocument() throws {
        let temp = try TempTestDirectory(prefix: "MacSweepUserRuleWriteFailureTests")
        let fileURL = temp.url.appending(path: UserProtectionRules.protectFilename)
        let originalContents = "# Important\n~/Documents/private\n"
        try originalContents.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = UserProtectionRuleStore(
            homeURL: temp.url,
            fileManager: .default,
            readContents: { try String(contentsOf: $0, encoding: .utf8) },
            writeContents: { _, _ in throw InjectedWriteFailure() }
        )
        var document = try store.load(.protect)
        var entries = document.entries
        entries[0].pattern = "~/Documents/edited"
        try document.replaceEntries(entries)

        #expect(throws: UserProtectionRuleFileError.self) {
            try store.save(document)
        }
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == originalContents)
        #expect(document.renderedContents.contains("~/Documents/edited"))
    }

    @Test func invalidFileReportsLineWithoutChangingItsContents() throws {
        let temp = try TempTestDirectory(prefix: "MacSweepInvalidUserRuleTests")
        let fileURL = temp.url.appending(path: UserProtectionRules.ignoreFilename)
        let originalContents = "# Valid comment\n!\n~/still-present\n"
        try originalContents.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = UserProtectionRuleStore(homeURL: temp.url)

        #expect(throws: UserProtectionRuleFileError.self) {
            _ = try store.load(.ignore)
        }
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == originalContents)
    }
}
