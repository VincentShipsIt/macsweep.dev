import Darwin
import Foundation
import Testing

@testable import MacSweepCLIKit
@testable import MacSweepCore

struct DoctorRepairTests {
    @Test func exactBrokenLinkMovesWithoutFollowingOrTouchingItsNeighbor() async throws {
        let fixture = try RepairFixture()
        let link = try fixture.link("old-tool", destination: "missing")
        let neighbor = fixture.bin.appendingPathComponent("keep")
        try Data([1, 2, 3]).write(to: neighbor)
        let finding = try #require(try DoctorFileChecks.brokenLink(link))
        let service = fixture.service()
        let result = await service.repair([finding], confirmed: true, administratorAcknowledged: false)
        #expect(result.itemsProcessed == 1)
        #expect(result.errors.isEmpty)
        #expect(result.accounting?.movedToTrashBytes == finding.stamp?.size)
        #expect(result.accounting?.permanentlyRemovedTargetBytes == 0)
        #expect(try Data(contentsOf: neighbor) == Data([1, 2, 3]))
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.trash.appendingPathComponent("old-tool").path) == "missing")
    }

    @Test func changedLinkAndNewlyProtectedPathNeverDispatch() async throws {
        let fixture = try RepairFixture()
        let link = try fixture.link("changed", destination: "missing")
        let original = try #require(try DoctorFileChecks.brokenLink(link))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "different")
        let result = await fixture.service().repair([original], confirmed: true, administratorAcknowledged: false)
        #expect(result.itemsProcessed == 0 && result.errors.count == 1)
        let fresh = try #require(try DoctorFileChecks.brokenLink(link))
        var service = fixture.service()
        let rules = UserProtectionRules(ignoreContents: "", protectContents: link.path, homeURL: fixture.home)
        service.rules = { rules }
        let protected = await service.repair([fresh], confirmed: true, administratorAcknowledged: false)
        #expect(protected.itemsProcessed == 0 && protected.errors.count == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "different")
    }

    @Test func aggregateCapBlocksEveryRepairBeforeAnyMove() async throws {
        let fixture = try RepairFixture()
        let first = try #require(try DoctorFileChecks.brokenLink(try fixture.link("one", destination: "missing-one")))
        let second = try #require(try DoctorFileChecks.brokenLink(try fixture.link("two", destination: "missing-two")))
        let cap = DeletionGuard(maxTotalSize: max(first.stamp?.size ?? 0, second.stamp?.size ?? 0))
        let result = await fixture.service().repair(
            [first, second], confirmed: true,
            administratorAcknowledged: false, guard: cap)
        #expect(result.itemsProcessed == 0 && result.errors.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    }

    @Test func missingProgramRestoredAfterReviewRetainsLaunchItem() async throws {
        let fixture = try RepairFixture()
        let plist = fixture.agents.appendingPathComponent("orphan.plist")
        let program = fixture.bin.appendingPathComponent("restored")
        try PropertyListSerialization.data(fromPropertyList: ["Program": program.path], format: .xml, options: 0).write(
            to: plist)
        let finding = try #require(try DoctorFileChecks.launchItem(plist, home: fixture.home))
        try Data([1]).write(to: program)
        let result = await fixture.service().repair([finding], confirmed: true, administratorAcknowledged: false)
        #expect(result.itemsProcessed == 0 && result.errors.count == 1)
        #expect(FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func privilegeChangeAfterReviewCannotDispatchWithoutAcknowledgement() async throws {
        let fixture = try RepairFixture()
        let link = try fixture.link("privilege-changed", destination: "missing")
        let finding = try #require(try DoctorFileChecks.brokenLink(link))
        #expect(!finding.requiresAdministrator)
        #expect(chmod(fixture.bin.path, 0o555) == 0)
        defer { _ = chmod(fixture.bin.path, 0o755) }
        var service = fixture.service()
        service.privilegedTrash = { _ in Issue.record("Unexpected administrator dispatch") }
        let result = await service.repair([finding], confirmed: true, administratorAcknowledged: false)
        #expect(result.itemsProcessed == 0 && result.errors.count == 1)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "missing")
    }

    @Test func unsupportedAdministratorRepairIsRetainedBeforeAuthorization() throws {
        let fixture = try RepairFixture()
        let link = try fixture.link("not-a-system-root", destination: "missing")
        let finding = try #require(try DoctorFileChecks.brokenLink(link))
        #expect(!PrivilegedRunner.doctorAdministratorRepairIsSupported(finding))
        #expect(throws: (any Error).self) {
            _ = try PrivilegedRunner.doctorRepairScript(finding, home: fixture.home)
        }
    }

    @Test func cliIsReadOnlyAndRejectsRepairArguments() throws {
        #expect(try CLICommandParser.parse(["doctor"]) == .doctor(.text))
        #expect(try CLICommandParser.parse(["doctor", "--format", "json"]) == .doctor(.json))
        #expect(throws: (any Error).self) { try CLICommandParser.parse(["doctor", "--fix"]) }
        let result = CleanupResult(itemsProcessed: 1, bytesFreed: 0)
        #expect(result.processedTargetSizeText(estimateAvailable: false) == "Processed target size unavailable")
        #expect(result.processedTargetSizeText(estimateAvailable: true).contains("(estimate)"))
    }
}

private struct RepairFixture: ~Copyable {
    let temp: TempTestDirectory
    var home: URL { temp.url }
    var bin: URL { home.appendingPathComponent("bin") }
    var agents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    var trash: URL { home.appendingPathComponent("Trash") }
    init() throws {
        let owned = try TempTestDirectory(prefix: "DoctorRepair")
        let root = owned.url
        for relative in ["bin", "Library/LaunchAgents", "Trash"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        temp = consume owned
    }
    func link(_ name: String, destination: String) throws -> URL {
        let path = bin.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: path.path, withDestinationPath: destination)
        return path
    }
    func service() -> EnvironmentDoctorService {
        var service = EnvironmentDoctorService()
        service.paths = DoctorPaths(home: home, launchDirectories: [agents], binDirectories: [bin], brew: nil)
        service.rules = { .empty }
        let destination = trash
        service.trash = {
            try FileManager.default.moveItem(at: $0, to: destination.appendingPathComponent($0.lastPathComponent))
        }
        return service
    }
}
