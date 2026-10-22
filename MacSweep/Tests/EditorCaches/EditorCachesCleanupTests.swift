import Darwin
import Foundation
import Testing

@testable import MacSweepCore

struct EditorCachesCleanupTests {
    @Test func reappearingWorkspaceAndNewlyInstalledIDEPreventDispatch() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let missing = fixture.home.appending(path: "projects/missing")
        _ = try fixture.workspace(id: "dead", value: missing.absoluteString)
        let cache = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        var service = fixture.service()
        let preview = await service.scan()
        #expect(preview.findings.filter(\.isSelectable).count == 2)
        _ = try fixture.directory("projects/missing")
        service.applications = { EditorApplicationInventory(jetBrainsSelectors: ["IntelliJIdea2025.1"]) }
        service.trash = { _ in Issue.record("Fresh ownership guard bypassed") }
        let result = await service.remove(preview.findings)
        #expect(result.itemsProcessed == 0 && result.errors.count == 2)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func registeredExtensionVersionIsCheckedAgainAtCleanup() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        _ = try fixture.extensionVersion("1.0.0")
        _ = try fixture.extensionVersion("2.0.0")
        try fixture.registry(["2.0.0"])
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first { $0.isSelectable })
        try fixture.registry(["1.0.0", "2.0.0"])
        service.trash = { _ in Issue.record("Registered extension dispatched") }
        #expect(await service.remove([finding]).itemsProcessed == 0)
    }

    @Test func aggregateCapAppliesBeforeAnyRemovalAndFailuresContinueWithHonestTrashAccounting() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let first = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        _ = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.2")
        var service = fixture.service()
        let findings = await service.scan().findings
        #expect(findings.count == 2 && findings.allSatisfy(\.isSelectable))
        var attempts = 0
        service.trash = { _ in attempts += 1 }
        service.deletionGuard.maxTotalSize = 1
        #expect(await service.remove(findings).itemsProcessed == 0)
        #expect(attempts == 0)
        service.deletionGuard.maxTotalSize = 10_737_418_240
        service.trash = { path in
            attempts += 1
            if path.path == first.path { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: path)
        }
        let result = await service.remove(findings + findings)
        #expect(result.itemsProcessed == 1 && result.errors.count == 1 && attempts == 2)
        #expect(result.bytesFreed == 0)
        #expect(result.accounting?.movedToTrashBytes == 5)
    }

    @Test func identityReplacementContentChangesAndNewProtectionRulesAreRevalidated() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let target = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        var service = fixture.service()
        let initial = try #require(await service.scan().findings.first)
        try FileManager.default.moveItem(at: target, to: fixture.home.appending(path: "previous"))
        _ = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        service.trash = { _ in Issue.record("Changed target dispatched") }
        #expect(await service.remove([initial]).itemsProcessed == 0)
        let replaced = try #require(await service.scan().findings.first)
        try Data("new content".utf8).write(to: target.appending(path: "index"))
        #expect(await service.remove([replaced]).itemsProcessed == 0)
        let current = try #require(await service.scan().findings.first)
        service.protectionRules = {
            SafetyChecker(
                userRules: UserProtectionRules(
                    ignoreContents: "", protectContents: target.path + "\n",
                    homeURL: fixture.home))
        }
        #expect(await service.remove([current]).itemsProcessed == 0)
    }

    @Test func appStartOpenFilesLocksAndIncompleteActivityRetainCaches() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let target = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        service.trash = { _ in Issue.record("Active cache dispatched") }
        service.applications = { EditorApplicationInventory(runningIDs: ["com.jetbrains.intellij"]) }
        #expect(await service.remove([finding]).itemsProcessed == 0)
        service.applications = { EditorApplicationInventory() }
        service.activity = { DevProcessSnapshot(issues: ["process inventory unavailable"]) }
        #expect(await service.remove([finding]).itemsProcessed == 0)
        service.activity = { DevProcessSnapshot() }
        let descriptor = open(target.appending(path: "index").path, O_RDONLY)
        defer { close(descriptor) }
        #expect(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(await service.remove([finding]).itemsProcessed == 0)
        _ = flock(descriptor, LOCK_UN)
        service.activity = {
            DevProcessSnapshot(jobs: [
                DevProcessJob(
                    identity: DevProcessIdentity(pid: 4321, seconds: 1, microseconds: 0, executable: "/fixture/IDE"),
                    parentPID: 1, directory: fixture.home, arguments: ["IDE"],
                    openFiles: [target.appending(path: "index")],
                    sharedDependencies: [], inspectionIssue: nil)
            ])
        }
        #expect(await service.remove([finding]).itemsProcessed == 0)
    }
    @Test func noOpTrashCannotClaimSuccessAndCancelledScanIsIncomplete() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        _ = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        service.trash = { _ in }
        let result = await service.remove([finding])
        #expect(result.itemsProcessed == 0 && result.errors.count == 1)
        #expect(result.accounting?.movedToTrashBytes == 0)
        service.activity = {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return DevProcessSnapshot()
        }
        let task = Task { await service.scan() }
        await Task.yield()
        task.cancel()
        let cancelled = await task.value
        #expect(!cancelled.issues.isEmpty && cancelled.findings.allSatisfy { !$0.isSelectable })
    }

}
