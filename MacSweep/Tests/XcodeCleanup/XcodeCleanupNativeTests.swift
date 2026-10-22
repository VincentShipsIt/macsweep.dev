import Foundation
import Testing

@testable import MacSweepCore

struct XcodeCleanupNativeTests {
    @Test func nativeRuntimeRemovalUsesExactUUIDAndVerifiesDisappearance() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        let inventory = await service.scan()
        #expect(inventory.nativeCommandsAvailable)
        let target = try #require(inventory.targets.first)
        #expect(target.canRemove)
        let receipt = await service.remove([target], confirmed: true)
        #expect(receipt.removedIDs == [target.id])
        #expect(receipt.removedTargetBytes == 4096)
        #expect(receipt.trashedBytes == 0)
        let calls = await native.calls
        #expect(calls.contains(["simctl", "runtime", "delete", native.id.uuidString]))
        #expect(!calls.contains { $0.contains("unavailable") || $0.contains("all") })
    }

    @Test func nativeFailureHasNoFilesystemFallback() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        await native.configure(fail: true)
        let service = fixture.service(
            command: { try await native.invoke($0, $1, $2) },
            trash: { _ in
                Issue.record("Native failure must never invoke Trash")
            })
        let targets = await service.scan().targets
        let receipt = await service.remove(targets, confirmed: true)
        #expect(receipt.removedIDs.isEmpty)
        #expect(receipt.errors.count == 1)
        #expect(receipt.removedTargetBytes == 0)
    }

    @Test func availableAndUnknownRuntimeStateAreRetained() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        await native.configure(available: true)
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        await native.configure(state: "Mounting")
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
    }

    @Test func nativeInventoryFailureStillReportsFileTargets() async throws {
        let fixture = try XcodeFixture()
        _ = try fixture.directory("Library/Developer/CoreSimulator/Caches/old")
        let inventory = await fixture.service().scan()
        #expect(!inventory.nativeCommandsAvailable)
        #expect(inventory.targets.count == 1)
        #expect(inventory.targets.first?.canRemove == true)
        #expect(!inventory.issues.isEmpty)
    }
    @Test func unavailableShutdownDeviceUsesExactNativeActionAndRetainsItsRuntime() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        await native.configureDevice(state: "Shutdown")
        let path = try fixture.directory("Library/Developer/CoreSimulator/Devices/\(native.id.uuidString)")
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        let inventory = await service.scan()
        let device = try #require(inventory.targets.first { $0.category == .simulators })
        #expect(device.canRemove)
        #expect(inventory.targets.first { $0.category == .runtimes }?.canRemove == false)
        let receipt = await service.remove([device], confirmed: true)
        #expect(receipt.removedIDs == [device.id])
        let calls = await native.calls
        #expect(calls.contains(["simctl", "delete", native.id.uuidString]))
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func bootedAvailableAndUnknownDevicesAreRetained() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        _ = try fixture.directory("Library/Developer/CoreSimulator/Devices/\(native.id.uuidString)")
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        for state in ["Booted", "Creating", "Unknown"] {
            await native.configureDevice(state: state)
            #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
        }
        await native.configureDevice(state: "Shutdown", available: true)
        #expect(await service.scan().targets.allSatisfy { !$0.canRemove })
    }

    @Test func selectedDeveloperChangeInvalidatesNativeReceipt() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        let targets = await service.scan().targets
        #expect(targets.first?.canRemove == true)
        await native.select("/Applications/Xcode-Beta.app/Contents/Developer")
        let receipt = await service.remove(targets, confirmed: true)
        #expect(receipt.removedIDs.isEmpty)
        let calls = await native.calls
        #expect(!calls.contains { $0.contains("delete") && !$0.contains("help") })
    }

    @Test func selectedXcodeIsRetainedAndImpostorBundlesAreIgnored() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        let app = try fixture.directory("Applications/Xcode.app/Contents")
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        _ = try fixture.directory("Applications/Xcode-Impostor.app/Contents")
        await native.select(app.appendingPathComponent("Developer").path)
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        let targets = await service.scan().targets.filter { $0.category == .applications }
        #expect(targets.count == 1)
        #expect(targets.first?.canRemove == false)
        #expect(targets.first?.retentionReason?.contains("Selected Xcode") == true)
    }

    @Test func bootedDeviceUnderUnrelatedRuntimeRetainsNativeRuntime() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        await native.configureUnrelatedBoot(booted: true)
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        let inventory = await service.scan()
        let runtime = try #require(inventory.targets.first { $0.category == .runtimes })
        #expect(!runtime.canRemove)
        #expect(runtime.retentionReason?.contains("booted") == true)
    }

    @Test func bootBetweenReviewAndFinalNativeDispatchPreventsDeletion() async throws {
        let fixture = try XcodeFixture()
        let native = XcodeNativeFixture()
        await native.configureUnrelatedBoot(afterSummaries: 3)
        let service = fixture.service(command: { try await native.invoke($0, $1, $2) })
        let inventory = await service.scan()
        let target = try #require(inventory.targets.first { $0.category == .runtimes })
        #expect(target.canRemove)
        let receipt = await service.remove([target], confirmed: true)
        #expect(receipt.removedIDs.isEmpty)
        let calls = await native.calls
        #expect(!calls.contains { $0.contains("delete") && !$0.contains("help") })
    }

}
