import Foundation
import Testing

@testable import MacSweepCore

struct ToolchainRemovalTests {
    @Test func nativeSuccessCreditsCountWithoutInventingBytes() async throws {
        let fixture = try ToolchainFixture()
        let path = try fixture.install()
        let runner = ToolchainRecordingRunner()
        await runner.configure(removePaths: ["3.8.0": path])
        let service = fixture.service(runner: runner)
        let before = try await service.inventory()
        let result = await service.remove(before.installations)
        #expect(result.itemsProcessed == 1)
        #expect(result.bytesFreed == 0)
        #expect(result.errors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let commands = await runner.mutations
        #expect(commands.count == 1)
        #expect(commands.first?.arguments.contains("PYENV_ROOT=" + fixture.location.root.path) == true)
    }

    @Test func changedGlobalSelectionPreventsNativeDispatch() async throws {
        let fixture = try ToolchainFixture()
        try fixture.install()
        let runner = ToolchainRecordingRunner()
        let service = fixture.service(runner: runner)
        let before = try await service.inventory()
        try Data("3.8.0".utf8).write(to: fixture.location.root.appendingPathComponent("version"))
        let result = await service.remove(before.installations)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
        #expect(await runner.mutations.isEmpty)
    }

    @Test func contentAndExecutableChangesPreventDispatch() async throws {
        let fixture = try ToolchainFixture()
        let path = try fixture.install()
        let runner = ToolchainRecordingRunner()
        let service = fixture.service(runner: runner)
        let before = try await service.inventory()
        try Data("modified".utf8).write(to: path.appendingPathComponent("new-file"))
        let changed = await service.remove(before.installations)
        #expect(changed.itemsProcessed == 0)
        let fresh = try await service.inventory()
        try Data("changed manager".utf8).write(to: try #require(fixture.location.executable))
        let changedManager = await service.remove(fresh.installations)
        #expect(changedManager.itemsProcessed == 0)
        #expect(await runner.mutations.isEmpty)
    }

    @Test func missingVersionAndFailedCommandAreFactualFailures() async throws {
        let fixture = try ToolchainFixture()
        let path = try fixture.install()
        let runner = ToolchainRecordingRunner()
        let service = fixture.service(runner: runner)
        let before = try await service.inventory()
        await runner.configure(failure: true)
        let failed = await service.remove(before.installations)
        #expect(failed.errors.count == 1)
        #expect(failed.itemsProcessed == 0)
        #expect(failed.bytesFreed == 0)
        #expect(FileManager.default.fileExists(atPath: path.path))
        try FileManager.default.removeItem(at: path)
        let absent = await service.remove(before.installations)
        #expect(absent.itemsProcessed == 0)
        #expect(absent.errors.count == 1)
    }

    @Test func retainedRuntimeDoesNotReceiveSuccessCredit() async throws {
        let fixture = try ToolchainFixture()
        try fixture.install()
        let service = fixture.service()
        let before = try await service.inventory()
        let result = await service.remove(before.installations)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
        #expect(result.bytesFreed == 0)
    }

    @Test func newlyCreatedReferenceDuringFinalActivityCheckBlocksDispatch() async throws {
        let fixture = try ToolchainFixture()
        try fixture.install()
        let runner = ToolchainRecordingRunner()
        let mutation = ToolchainReferenceMutation(path: fixture.projects.appendingPathComponent(".python-version"))
        var service = fixture.service(runner: runner)
        service.activity = { try await mutation.snapshot() }
        let before = try await service.inventory()
        let result = await service.remove(before.installations)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
        #expect(await runner.mutations.isEmpty)
    }

    @Test func aggregateCapBlocksBeforeAnyUninstall() async throws {
        let fixture = try ToolchainFixture()
        try fixture.install()
        let runner = ToolchainRecordingRunner()
        let service = fixture.service(runner: runner)
        let before = try await service.inventory()
        var guardrail = DeletionGuard()
        guardrail.maxTotalSize = 1
        let result = await service.remove(before.installations, guard: guardrail)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 1)
        #expect(await runner.mutations.isEmpty)
    }

    @Test func multipleVersionsReportPartialResults() async throws {
        let fixture = try ToolchainFixture()
        let removed = try fixture.install("3.8.0")
        try fixture.install("3.9.0")
        let runner = ToolchainRecordingRunner()
        await runner.configure(removePaths: ["3.8.0": removed])
        let service = fixture.service(runner: runner)
        let before = try await service.inventory()
        let result = await service.remove(before.installations)
        #expect(result.itemsProcessed == 1)
        #expect(result.errors.count == 1)
        #expect(result.bytesFreed == 0)
    }
}

private actor ToolchainReferenceMutation {
    let path: URL
    var calls = 0
    init(path: URL) { self.path = path }
    func snapshot() throws -> DevProcessSnapshot {
        calls += 1
        if calls == 3 { try Data("3.8.0".utf8).write(to: path) }
        return DevProcessSnapshot()
    }
}
