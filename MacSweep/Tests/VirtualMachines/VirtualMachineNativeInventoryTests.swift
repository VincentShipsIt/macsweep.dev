import Foundation
import Testing

@testable import MacSweepCore

struct VirtualMachineNativeInventoryTests {
    @Test func everyManagerUsesNativeReadOnlyInventoryAndUnsupportedActionsStayLocked() async throws {
        let fixture = try VirtualMachineFixture()
        let native = VirtualMachineNative(
            home: fixture.root, command: Self.command,
            executable: { manager in
                manager == .claude ? nil : "/fixture/\(manager.rawValue)"
            })
        let inventory = await native.scan()
        #expect(inventory.issues.isEmpty)
        #expect(inventory.installedManagers.count == 8)
        #expect(inventory.completeManagers.count == 8)
        #expect(inventory.targets.count == 7)
        #expect(inventory.targets.allSatisfy { !$0.canRemove })
        #expect(inventory.targets.first { $0.manager == .orbStack }?.lastUsed != nil)
    }

    @Test func duplicateNativeIdentifiersAndUnknownWarningsFailClosed() async {
        let native = VirtualMachineNative(
            home: URL(fileURLWithPath: "/Users/example"),
            command: { _, args, _ in
                if args == ["list", "--json"] {
                    return ProcessResult(status: 0, output: "[{\"name\":\"one\"},{\"name\":\"one\"}]", error: "")
                }
                return ProcessResult(status: 0, output: "[]", error: "partial inventory warning")
            }, executable: { $0 == .colima ? "/fixture/colima" : nil })
        let inventory = await native.scan()
        #expect(!inventory.issues.isEmpty)
        #expect(!inventory.completeManagers.contains(.colima))
    }

    private static let command: VirtualMachineCommand = { executable, arguments, _ in
        let manager = URL(fileURLWithPath: executable).lastPathComponent
        let uuid = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let text: String
        switch manager {
        case "lima":
            if arguments == ["--version"] {
                text = "limactl version 2.2.1"
            } else if arguments == ["delete", "--help"] {
                text = "delete INSTANCE --force Forcibly kill"
            } else {
                text = "[{\"name\":\"example\",\"dir\":\"/Users/example/.lima/example\",\"status\":\"Running\"}]"
            }
        case "colima": text = "{\"name\":\"default\",\"status\":\"Stopped\",\"disk\":107374182400}"
        case "orbStack":
            if arguments == ["list", "--help"] {
                text = "--format json"
            } else {
                text = "[{\"name\":\"linux\",\"state\":\"Running\",\"lastUsedAt\":\"2026-01-02T03:04:05Z\"}]"
            }
        case "utm": text = "UUID Status Name\n\(uuid) started UTM machine"
        case "parallels": text = "[{\"ID\":\"\(uuid)\",\"Name\":\"Windows\",\"State\":\"suspended\"}]"
        case "virtualBox":
            text = arguments == ["list", "vms"] ? "\"Windows\" {\(uuid)}" : "name=\"Windows\"\nVMState=\"running\""
        case "vagrant": text = "1,,box-name,vendor/box\n1,,box-provider,virtualbox\n1,,box-version,1.0.0"
        case "docker": text = "default"
        default: throw VirtualMachineError("Unexpected manager")
        }
        return ProcessResult(status: 0, output: text, error: "")
    }
}
