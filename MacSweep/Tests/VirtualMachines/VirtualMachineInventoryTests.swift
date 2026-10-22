import Foundation
import Testing

@testable import MacSweepCore

struct VirtualMachineInventoryTests {
    @Test func absentManagersAreQuiet() async throws {
        let fixture = try VirtualMachineFixture()
        let inventory = await fixture.service().scan()
        #expect(inventory.installedManagers.isEmpty)
        #expect(inventory.targets.isEmpty)
        #expect(inventory.issues.isEmpty)
    }

    @Test func allRequestedLayoutsArePersistentAndNeverAutomaticallyRemovable() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory(".orbstack/data")
        _ = try fixture.directory(".colima/_lima/_disks")
        _ = try fixture.directory(".lima/test", marker: "lima.yaml")
        _ = try fixture.directory("Library/Containers/com.utmapp.UTM/Data/Documents/Test.utm", marker: "config.plist")
        _ = try fixture.directory("Documents/Parallels/Test.pvm", marker: "config.pvs")
        _ = try fixture.directory("VirtualBox VMs/Test", marker: "Test.vbox")
        _ = try fixture.directory(".vagrant.d/boxes/example-VAGRANTSLASH-box/1.0.0/virtualbox")
        _ = try fixture.directory("Library/Containers/com.docker.docker/Data/vms/0")
        try fixture.bundle("Claude", id: "com.anthropic.claudefordesktop")
        _ = try fixture.directory("Library/Application Support/Claude/vm_bundles/claudevm.bundle")
        _ = try fixture.directory("Library/Application Support/Claude/claude-code-vm")
        _ = try fixture.directory("Library/Application Support/Claude/local-agent-mode-sessions")
        let inventory = await fixture.service().scan()
        #expect(inventory.installedManagers.count == 9)
        #expect(inventory.targets.allSatisfy { $0.persistentState })
        #expect(inventory.targets.allSatisfy { !$0.canRemove })
        #expect(inventory.targets.allSatisfy { $0.measuredBytes != nil })
        #expect(inventory.targets.allSatisfy { $0.lastUsed == nil })
        #expect(inventory.targets.filter { $0.manager == .claude }.count == 3)
    }

    @Test func appOwnershipAndRulesAreRequiredButProtectedStateStaysVisible() async throws {
        let fixture = try VirtualMachineFixture()
        _ = try fixture.directory("Library/Application Support/Claude/vm_bundles/claudevm.bundle")
        #expect(await fixture.service().scan().targets.isEmpty)
        try fixture.bundle("Claude", id: "com.anthropic.claudefordesktop")
        let protected = UserProtectionRules(
            ignoreContents: "", protectContents: "Library/Application Support/Claude",
            homeURL: fixture.root)
        let inventory = await fixture.service(rules: { protected }).scan()
        #expect(inventory.targets.count == 1)
        #expect(inventory.targets.first?.canRemove == false)
        #expect(inventory.targets.first?.retentionReason?.contains("Protected") == true)
    }

    @Test func linkedAndChangingDiskContentsNeverBecomeRemovalEvidence() async throws {
        let fixture = try VirtualMachineFixture()
        let root = try fixture.directory(".lima/example", marker: "lima.yaml")
        let outside = try fixture.directory("outside")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        let native = VirtualMachineNativeFixture(home: fixture.root)
        let inventory = await fixture.service(native: native).scan()
        #expect(inventory.targets.first?.canRemove == false)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func nativeParsersCoverJsonTablesMachinePropertiesAndVagrant() throws {
        #expect(try VirtualMachineParsing.objects("{\"name\":\"one\"}\n{\"name\":\"two\"}").count == 2)
        #expect(try VirtualMachineParsing.objects("[]").isEmpty)
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        #expect(
            try VirtualMachineParsing.utm("UUID Status Name\n\(uuid) stopped Ubuntu with spaces").first?.name
                == "Ubuntu with spaces")
        #expect(try VirtualMachineParsing.virtualBoxIDs("\"VM name\" {\(uuid)}") == [uuid])
        #expect(try VirtualMachineParsing.keyValues("VMState=\"poweroff\"\ncpus=2")["VMState"] == "poweroff")
        let box = "1,,box-name,hashicorp/example\n1,,box-provider,virtualbox\n1,,box-version,1.0.0\n"
        #expect(try VirtualMachineParsing.vagrant(box).first?.provider == "virtualbox")
        #expect(!VirtualMachineParsing.validName("--all"))
        #expect(!VirtualMachineParsing.validComponent("../outside"))
        #expect(throws: (any Error).self) { try VirtualMachineParsing.utm("bad") }
        #expect(throws: (any Error).self) { try VirtualMachineParsing.virtualBoxIDs("unknown") }
        #expect(throws: (any Error).self) { try VirtualMachineParsing.vagrant("1,,box-version,1.0.0") }
    }
}
