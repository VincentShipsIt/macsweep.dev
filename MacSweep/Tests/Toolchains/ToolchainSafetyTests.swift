import Foundation
import Testing

@testable import MacSweepCore

struct ToolchainSafetyTests {
    @Test func absentManagersAreSilentWithoutActivityInspection() async throws {
        var service = ToolchainService()
        service.locationsOverride = []
        service.activity = { throw DevArtifactSafetyError("should not run") }
        let inventory = try await service.inventory()
        #expect(inventory.installations.isEmpty)
        #expect(inventory.issues.isEmpty)
    }

    @Test func oldUnreferencedRuntimeIsReviewable() async throws {
        let fixture = try ToolchainFixture()
        try fixture.install()
        let inventory = try await fixture.service().inventory()
        let item = try #require(inventory.installations.first)
        #expect(item.status == .stale)
        #expect(item.isSelectable)
        #expect(item.size == 4096)
        #expect(item.command?.arguments.suffix(3) == ["uninstall", "-f", "3.8.0"])
    }

    @Test func globalSelectionAndRepoReferencesAreLocked() async throws {
        let fixture = try ToolchainFixture()
        try fixture.install("3.8.0")
        try fixture.install("3.9.0")
        try Data("3.8.0".utf8).write(to: fixture.location.root.appendingPathComponent("version"))
        try Data("3.9".utf8).write(to: fixture.projects.appendingPathComponent(".python-version"))
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.count == 2)
        #expect(inventory.installations.allSatisfy { $0.status == .active && !$0.isSelectable })
    }

    @Test func incompleteReferencesAndUnknownAliasesAreLocked() async throws {
        let fixture = try ToolchainFixture()
        try fixture.install()
        try Data("unknown-alias".utf8).write(to: fixture.projects.appendingPathComponent(".python-version"))
        let service = fixture.service()
        let aliasInventory = try await service.inventory()
        #expect(aliasInventory.installations.first?.status == .unknown)
        let budgetInventory = try await service.inventory(policy: ToolchainPolicy(maximumReferenceEntries: 0))
        #expect(!budgetInventory.issues.isEmpty)
        #expect(budgetInventory.installations.first?.isSelectable == false)
    }

    @Test func linkedEnvironmentProtectsRuntime() async throws {
        let fixture = try ToolchainFixture()
        let path = try fixture.install()
        let config = "home = " + path.appendingPathComponent("bin").path
        try Data(config.utf8).write(to: fixture.projects.appendingPathComponent("pyvenv.cfg"))
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.first?.status == .active)
        #expect(inventory.installations.first?.isSelectable == false)
    }

    @Test func liveProcessAndIncompleteActivityAreLocked() async throws {
        let fixture = try ToolchainFixture()
        let path = try fixture.install()
        var service = fixture.service()
        service.activity = {
            DevProcessSnapshot(jobs: [
                DevProcessJob(
                    identity: .init(
                        pid: 424242, seconds: 1, microseconds: 0,
                        executable: path.appendingPathComponent("bin/python").path),
                    parentPID: 1, directory: path, arguments: ["python"], openFiles: [], sharedDependencies: [],
                    inspectionIssue: nil)
            ])
        }
        let active = try await service.inventory()
        #expect(active.installations.first?.status == .active)
        service.activity = { DevProcessSnapshot(issues: ["fixture incomplete"]) }
        let unknown = try await service.inventory()
        #expect(unknown.installations.first?.status == .unknown)
    }

    @Test func unsupportedNativeCommandAndJDKRemainInventoryOnly() async throws {
        let fixture = try ToolchainFixture(manager: .java)
        try fixture.install("jdk-17")
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.count == 1)
        #expect(inventory.installations.first?.status == .unknown)
        #expect(inventory.installations.first?.command == nil)
    }

    @Test func externalRuntimeDependencyIsRetained() async throws {
        let fixture = try ToolchainFixture()
        let path = try fixture.install()
        try FileManager.default.createSymbolicLink(
            at: path.appendingPathComponent("external"), withDestinationURL: fixture.projects)
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.first?.status == .unknown)
        #expect(inventory.installations.first?.isSelectable == false)
    }
}
