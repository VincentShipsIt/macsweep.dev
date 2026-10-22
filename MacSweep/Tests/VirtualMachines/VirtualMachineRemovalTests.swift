import Foundation
import Testing

@testable import MacSweepCore

struct VirtualMachineRemovalTests {
    @Test func exactStoppedLimaRemovalIsVerifiedAndNeverClaimsCausalFreedBytes() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory(".lima/example", marker: "lima.yaml")
        let native = VirtualMachineNativeFixture(home: fixture.root)
        let service = fixture.service(native: native)
        let inventory = await service.scan()
        let target = try #require(inventory.targets.first)
        #expect(target.canRemove)
        #expect(target.measuredBytes ?? 0 < target.virtualCapacity ?? 0)
        let receipt = await service.remove([target], confirmed: true)
        #expect(receipt.errors.isEmpty)
        #expect(receipt.removedIDs == [target.id])
        #expect(native.deletedNames == ["example"])
        #expect(native.calls.contains(["--tty=false", "delete", "example"]))
        #expect(!native.calls.contains { $0.contains("--force") || $0.contains("stop") })
        #expect(receipt.result.accounting?.toolProcessedBytes == target.measuredBytes)
        #expect(receipt.observation != nil)
    }

    @Test func runningProtectedUnknownAndUnsupportedMachinesAreLocked() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory(".lima/example", marker: "lima.yaml")
        let native = VirtualMachineNativeFixture(home: fixture.root)
        let service = fixture.service(native: native)
        for status in ["Running", "Broken", "Installing", "Unknown"] {
            native.update { $0.rows[0]["status"] = status }
            #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        }
        native.update {
            $0.rows[0]["status"] = "Stopped"
            $0.rows[0]["protected"] = true
        }
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        native.update {
            $0.rows[0]["protected"] = false
            $0.rows[0]["additionalDisks"] = [["name": "shared"]]
        }
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        native.update {
            $0.rows[0].removeValue(forKey: "additionalDisks")
            $0.version = "limactl version 99.0"
        }
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
    }

    @Test func bootOrProtectionRaceAtFinalNativeCheckPreventsDeletion() async throws {
        for protect in [false, true] {
            let fixture = try VirtualMachineFixture()
            _ = try fixture.directory(".lima/example", marker: "lima.yaml")
            let native = VirtualMachineNativeFixture(home: fixture.root)
            let service = fixture.service(native: native)
            let target = try #require(await service.scan().targets.first)
            #expect(target.canRemove)
            native.update { if protect { $0.protectAfterLists = 3 } else { $0.bootAfterLists = 3 } }
            let receipt = await service.remove([target], confirmed: true)
            #expect(receipt.removedIDs.isEmpty)
            #expect(native.deletedNames.isEmpty)
        }
    }

    @Test func aggregateCapBlocksEveryDispatchAndConfirmationIsMandatory() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory(".lima/one", marker: "lima.yaml")
        _ = try fixture.directory(".lima/two", marker: "lima.yaml")
        let native = VirtualMachineNativeFixture(home: fixture.root, names: ["one", "two"])
        let targets = await fixture.service(native: native).scan().targets
        let total = targets.compactMap(\.measuredBytes).reduce(0, +)
        #expect(targets.count == 2)
        #expect(targets.allSatisfy { $0.canRemove })
        let service = fixture.service(native: native, limit: total - 1)
        #expect(await service.remove(targets, confirmed: true).removedIDs.isEmpty)
        #expect(await service.remove(targets, confirmed: false).removedIDs.isEmpty)
        #expect(native.deletedNames.isEmpty)
    }

    @Test func nativeFailurePreservesRemainingTargetsAndReportsPartialReceipt() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory(".lima/one", marker: "lima.yaml")
        let second = try fixture.directory(".lima/two", marker: "lima.yaml")
        let native = VirtualMachineNativeFixture(home: fixture.root, names: ["one", "two"])
        native.update { $0.failNames = ["two"] }
        let service = fixture.service(native: native)
        let targets = await service.scan().targets
        let receipt = await service.remove(targets, confirmed: true)
        #expect(receipt.removedIDs.count == 1)
        #expect(receipt.errors.count == 1)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func changedIdentityContentsAndRulesPreventRemoval() async throws {
        let fixture = try VirtualMachineFixture()
        let root = try fixture.directory(".lima/example", marker: "lima.yaml")
        let native = VirtualMachineNativeFixture(home: fixture.root)
        let service = fixture.service(native: native)
        let target = try #require(await service.scan().targets.first)
        try Data("modified".utf8).write(to: root.appendingPathComponent("disk.img"))
        #expect(await service.remove([target], confirmed: true).removedIDs.isEmpty)
        let reviewed = try #require(await service.scan().targets.first)
        let protected = UserProtectionRules(ignoreContents: "", protectContents: root.path, homeURL: fixture.root)
        let changedRules = fixture.service(native: native, rules: { protected })
        #expect(await changedRules.remove([reviewed], confirmed: true).removedIDs.isEmpty)
        #expect(native.deletedNames.isEmpty)
    }

    @Test func incompleteProcessActivityAndUnknownNativeStatePreserveVisibleMachine() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory(".lima/example", marker: "lima.yaml")
        let native = VirtualMachineNativeFixture(home: fixture.root)
        let service = fixture.service(native: native, activity: { DevProcessSnapshot(issues: ["unknown"]) })
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        native.update { $0.rows[0]["hostAgentPID"] = "unknown" }
        let inventory = await fixture.service(native: native).scan()
        #expect(inventory.targets.count == 1)
        #expect(inventory.targets.first?.canRemove == false)
        #expect(native.deletedNames.isEmpty)
    }
    @Test func staleProcessMetadataRetainsStoppedMachineBeforeNativeTeardown() async throws {
        let fixture = try VirtualMachineFixture()
        let root = try fixture.directory(".lima/example", marker: "lima.yaml")
        try Data("12345".utf8).write(to: root.appendingPathComponent("driver-server.pid"))
        let native = VirtualMachineNativeFixture(home: fixture.root)
        let inventory = await fixture.service(native: native).scan()
        #expect(inventory.targets.first?.canRemove == false)
        #expect(inventory.targets.first?.retentionReason?.contains("metadata") == true)
        #expect(native.deletedNames.isEmpty)
    }

    @Test func malformedProtectionAndProcessFieldsNeverBecomeStoppedEvidence() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory(".lima/example", marker: "lima.yaml")
        let native = VirtualMachineNativeFixture(home: fixture.root)
        let service = fixture.service(native: native)
        native.update { $0.rows[0]["protected"] = 0 }
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        native.update {
            $0.rows[0]["protected"] = false
            $0.rows[0]["hostAgentPID"] = false
        }
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        native.update {
            $0.rows[0]["hostAgentPID"] = 0
            $0.rows[0]["additionalDisks"] = "unknown"
        }
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        #expect(native.deletedNames.isEmpty)
    }

}
