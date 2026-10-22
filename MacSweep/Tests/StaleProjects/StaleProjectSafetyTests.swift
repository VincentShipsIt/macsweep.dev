import Darwin
import Foundation
@testable import MacSweepCore
import Testing

struct StaleProjectSafetyTests {
    @Test func artifactOnlySweepPreservesSourceConfigurationsAndActivityData() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        var service = fixture.service()
        service.artifactModule.remove = { target in
            guard target.lastPathComponent == "node_modules" else { throw DevArtifactSafetyError("Fixture scope.") }
            try FileManager.default.removeItem(at: target)
        }
        let project = try await fixture.project(service)
        #expect(project.age == .recent)
        #expect(!project.eligibleArtifacts.isEmpty)
        let result = await service.sweep(project.eligibleArtifacts)
        #expect(result.errors.isEmpty)
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 0)
        for name in ["package.json", "tsconfig.json", "package-lock.json", "capture.json", "conversation.json",
                     "ignored-source/notes.txt", ".git/HEAD"] {
            #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: name).path))
        }
        #expect(service.history.history().map(\.kind) == [.artifactSweep])
    }

    @Test func liveSharedDependencyAndUnknownActivityRetainArtifacts() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        var service = fixture.service()
        let target = fixture.root.appending(path: "node_modules")
        let job = fixture.job(shared: [target])
        service.activity = { DevProcessSnapshot(jobs: [job]) }
        let active = try await fixture.project(service)
        #expect(active.eligibleArtifacts.isEmpty)
        #expect(active.artifacts.first?.devArtifactReceipt?.isEligible == false)
        service.activity = { DevProcessSnapshot(issues: ["fixture unknown process"]) }
        let unknown = try await fixture.project(service)
        #expect(unknown.eligibleArtifacts.isEmpty)
    }

    @Test func aggregateCapStopsAllArtifactDispatches() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        service.artifactModule.remove = { ledger.append($0) }
        var guardrail = DeletionGuard()
        guardrail.maxTotalSize = 1
        let project = try await fixture.project(service)
        let result = await service.sweep(project.eligibleArtifacts, deletionGuard: guardrail)
        #expect(result.itemsProcessed == 0)
        #expect(!result.errors.isEmpty)
        #expect(ledger.values.isEmpty)
    }

    @Test func verifiedBackupStillNeedsFreshActivityProtectionAndGit() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        service.moveToTrash = { ledger.append($0) }
        let receipt = try await service.createArchive(
            fixture.project(service), destination: fixture.home.appending(path: "backup.zip"),
        )
        service.activity = { DevProcessSnapshot(issues: ["fixture unknown"]) }
        let unknown = await service.trashCheckout(receipt)
        #expect(unknown.itemsProcessed == 0)
        let sharedJob = fixture.job(shared: [fixture.root])
        service.activity = { DevProcessSnapshot(jobs: [sharedJob]) }
        let active = await service.trashCheckout(receipt)
        #expect(active.itemsProcessed == 0)
        service.activity = { DevProcessSnapshot() }
        let rules = UserProtectionRules(ignoreContents: "", protectContents: fixture.root.path, homeURL: fixture.home)
        service.checker = { SafetyChecker(userRules: rules) }
        let protected = await service.trashCheckout(receipt)
        #expect(protected.itemsProcessed == 0)
        #expect(ledger.values.isEmpty)
    }

    @Test func successfulCheckoutTrashHasSeparateAccountingWithoutFreedByteCredit() async throws {
        let fixture = try StaleProjectFixture(checkoutTrashFixture: true)
        try await fixture.initialize()
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        service.moveToTrash = { ledger.append($0) }
        let receipt = try await service.createArchive(
            fixture.project(service), destination: fixture.home.appending(path: "backup.zip"),
        )
        let result = await service.trashCheckout(receipt)
        #expect(result.errors.isEmpty, Comment(rawValue: result.failureSummaryMessage ?? ""))
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 0)
        #expect(result.accounting?.movedToTrashBytes == receipt.manifest.allocatedBytes)
        #expect(ledger.values.map(\.path) == [fixture.root.path])
        #expect(service.history.history().map(\.kind) == [.checkoutTrash, .archive])
    }

    @Test func dirtyUnpushedAndLinkedWorktreesCannotAuthorizeCheckoutTrash() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        try Data("dirty".utf8).write(to: fixture.root.appending(path: "capture.json"))
        let dirty = await StaleProjectGit.inspect(fixture.root)
        #expect(dirty.isClean == false)
        #expect(dirty.trashBlocker != nil)
        try await fixture.git(["checkout", "--", "capture.json"])
        try await fixture.git(["update-ref", "-d", "refs/remotes/origin/main"])
        let unpushed = await StaleProjectGit.inspect(fixture.root)
        #expect((unpushed.unpushedCommits ?? 0) > 0)
        #expect(unpushed.trashBlocker != nil)
        let linked = fixture.home.appending(path: "linked")
        try await fixture.git(["worktree", "add", "-q", "-b", "linked", linked.path])
        let main = await StaleProjectGit.inspect(fixture.root)
        let worktree = await StaleProjectGit.inspect(linked)
        #expect(main.worktreeCount == 2)
        #expect(main.trashBlocker != nil)
        #expect(worktree.metadataIsContained == false)
        #expect(worktree.trashBlocker != nil)
    }

    @Test func cancellationPreventsManifestAndTrashDispatch() async throws {
        let fixture = try StaleProjectFixture()
        try await fixture.initialize()
        let cancellation = StaleProjectCancellation()
        cancellation.cancel()
        #expect(throws: CancellationError.self) {
            try StaleProjectManifest.capture(fixture.root, cancellation: cancellation)
        }
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        service.moveToTrash = { ledger.append($0) }
        let receipt = try await service.createArchive(
            fixture.project(service), destination: fixture.home.appending(path: "backup.zip"),
        )
        let frozen = service
        let operation = Task { await frozen.trashCheckout(receipt) }
        operation.cancel()
        #expect(await operation.value.itemsProcessed == 0)
        #expect(ledger.values.isEmpty)
    }

    @Test func lateIgnoredSourceMutationAfterActivityInspectionIsRetained() async throws {
        let fixture = try StaleProjectFixture(checkoutTrashFixture: true)
        try await fixture.initialize()
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        service.moveToTrash = { ledger.append($0) }
        let receipt = try await service.createArchive(
            try await fixture.project(service), destination: fixture.home.appending(path: "backup.zip"))
        service.activity = {
            try Data("late write".utf8).write(to: fixture.root.appending(path: "ignored-source/notes.txt"))
            return DevProcessSnapshot()
        }
        let result = await service.trashCheckout(receipt)
        #expect(result.itemsProcessed == 0)
        #expect(!result.errors.isEmpty)
        #expect(ledger.values.isEmpty)
    }

    @Test func cancellationAfterCompletedTrashPreservesSuccessReceipt() async throws {
        let fixture = try StaleProjectFixture(checkoutTrashFixture: true)
        try await fixture.initialize()
        var service = fixture.service()
        let ledger = StaleProjectMoveLedger()
        let (commits, continuation) = AsyncStream.makeStream(of: Void.self)
        let barrier = DispatchSemaphore(value: 0)
        service.moveToTrash = { url in
            ledger.append(url)
            continuation.yield(())
            guard barrier.wait(timeout: .now() + 5) == .success else {
                throw DevArtifactSafetyError("Fixture cancellation handshake timed out.")
            }
        }
        let receipt = try await service.createArchive(
            try await fixture.project(service), destination: fixture.home.appending(path: "backup.zip"))
        let frozen = service
        let operation = Task {
            let result = await frozen.trashCheckout(receipt)
            continuation.finish()
            return result
        }
        for await _ in commits {
            operation.cancel()
            barrier.signal()
            break
        }
        let result = await operation.value
        #expect(ledger.values.count == 1)
        #expect(result.itemsProcessed == 1)
        #expect(result.errors.isEmpty)
        #expect(service.history.history().first?.completedCount == 1)
    }

    @Test func readOnlyActualInventoryWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["MACSWEEP_READONLY_STALE_INVENTORY"] == "1" else { return }
        var service = StaleProjectsService()
        service.searchPaths = [URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()]
        service.policy.maximumRepositories = 2
        service.policy.inventoryTimeLimit = 30
        let inventory = try await service.inventory()
        #expect(!inventory.projects.isEmpty)
        let retained = inventory.projects.filter { $0.git.metadataIsContained == false }.count
        print("Read-only project inventory: \(inventory.projects.count) repositories; "
              + "\(inventory.issues.count) partial-coverage diagnostics; "
              + "\(retained) linked/external Git roots retained.")
    }

    @Test func signalsAndRemoteDisplayAreConservative() {
        var unborn = StaleProjectGitState()
        unborn.remote = "https://example.invalid/repo.git"
        unborn.isClean = true
        unborn.unpushedCommits = 0
        unborn.metadataIsContained = true
        unborn.worktreeCount = 1
        #expect(unborn.trashBlocker != nil)
        #expect(StaleProjectGit.checkoutDate("HEAD@{1700000000}") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(StaleProjectGit.checkoutDate("unknown") == nil)
        #expect(StaleProjectGit.sanitizedRemote("https://token:secret@example.invalid/repo?secret=x#token")
            == "https://example.invalid/repo")
        #expect(StaleProjectGit.sanitizedRemote("git@example.invalid:repo.git") == "example.invalid:repo.git")
    }
}
