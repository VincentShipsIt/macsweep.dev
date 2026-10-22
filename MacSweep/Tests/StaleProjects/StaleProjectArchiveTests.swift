import Darwin
import Foundation
@testable import MacSweepCore
import Testing

struct StaleProjectArchiveTests {
    @Test func realZipRoundTripPreservesIgnoredSourceAndRequiresSeparateTrash() async throws {
        let fixture = try StaleProjectFixture(checkoutTrashFixture: true)
        try await fixture.initialize()
        let source = fixture.root.appending(path: "ignored-source/notes.txt")
        try Data("resource bytes".utf8).withUnsafeBytes { bytes in
            try #require(setxattr(source.path, "dev.macsweep.fixture", bytes.baseAddress, bytes.count, 0, 0) == 0)
        }
        let outside = fixture.home.appending(path: "external-source.txt")
        try Data("outside source stays".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: "ignored-source/external-link"), withDestinationURL: outside)
        let service = fixture.service()
        let project = try await fixture.project(service)
        let receipt = try await service.createArchive(project, destination: fixture.home.appending(path: "backup.zip"))
        #expect(receipt.archiveBytes > 0)
        #expect(receipt.trashBlocker == nil)
        #expect(receipt.manifest.entries.contains { $0.relativePath == "ignored-source/notes.txt" })
        #expect(receipt.manifest.entries.contains { $0.relativePath == "conversation.json" })
        #expect(receipt.manifest.entries.contains {
            $0.relativePath == "ignored-source/external-link" && $0.content == outside.path
        })
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside source stays")
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
        try await service.archive.validate(receipt)
        #expect(service.history.history().map(\.kind) == [.archive])
    }

    @Test func archiveFailureNeverProducesTrashAuthorizationOrRemovesSource() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        service.moveToTrash = { ledger.append($0) }
        service.archive.runner = { _, _, _ in ProcessResult(status: 1, output: "", error: "fixture failure") }
        await #expect(throws: DevArtifactSafetyError.self) {
            try await service.createArchive(fixture.project(service),
                                            destination: fixture.home.appending(path: "failed.zip"))
        }
        #expect(ledger.values.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appending(path: "failed.zip").path))
        #expect(service.history.history().first?.completedCount == 0)
    }

    @Test func ignoredContentChangesAndArchiveTamperingRetainCheckout() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        service.moveToTrash = { ledger.append($0) }
        let receipt = try await service.createArchive(
            fixture.project(service), destination: fixture.home.appending(path: "backup.zip"),
        )
        try Data("new source".utf8).write(to: fixture.root.appending(path: "ignored-source/notes.txt"))
        let changed = await service.trashCheckout(receipt)
        #expect(changed.itemsProcessed == 0)
        #expect(!changed.errors.isEmpty)
        try Data("damaged".utf8).write(to: receipt.destination)
        let tampered = await service.trashCheckout(receipt)
        #expect(tampered.itemsProcessed == 0)
        #expect(ledger.values.isEmpty)
    }

    @Test func existingOrInternalDestinationIsNeverOverwritten() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        let service = fixture.service()
        let project = try await fixture.project(service)
        let existing = fixture.home.appending(path: "existing.zip")
        try Data("keep".utf8).write(to: existing)
        for target in [existing, fixture.root.appending(path: "inside.zip")] {
            await #expect(throws: DevArtifactSafetyError.self) { try await service.createArchive(
                project,
                destination: target,
            ) }
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
    }

    @Test func protectionAppliesAcrossSystemTemporaryDirectoryAliases() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        let source = fixture.root.appending(path: "capture.json")
        let path = try #require(realpath(source.path, nil))
        defer { free(path) }
        let rules = UserProtectionRules(
            ignoreContents: "", protectContents: String(cString: path), homeURL: fixture.home)
        #expect(throws: DevArtifactSafetyError.self) {
            try StaleProjectManifest.capture(fixture.root, checker: SafetyChecker(userRules: rules))
        }
    }

    @Test func boundedManifestProtectsAllContentAndRejectsSpecialFiles() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        var policy = StaleProjectPolicy()
        policy.maximumManifestEntries = 2
        #expect(throws: DevArtifactSafetyError.self) { try StaleProjectManifest.capture(fixture.root, policy: policy) }
        let rules = UserProtectionRules(
            ignoreContents: "",
            protectContents: fixture.root.appending(path: "capture.json").path,
            homeURL: fixture.home,
        )
        #expect(throws: DevArtifactSafetyError.self) {
            try StaleProjectManifest.capture(fixture.root, checker: SafetyChecker(userRules: rules))
        }
        let pipe = fixture.root.appending(path: "ignored-source/live.pipe")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: DevArtifactSafetyError.self) { try StaleProjectManifest.capture(fixture.root) }
    }
}
