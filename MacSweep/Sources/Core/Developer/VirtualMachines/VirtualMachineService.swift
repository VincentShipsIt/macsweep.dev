import Darwin
import Foundation

struct VirtualMachineService {
    let home: URL
    let applications: [URL]
    let command: VirtualMachineCommand
    let executable: @Sendable (VirtualMachineManager) -> String?
    let activity: @Sendable () async throws -> DevProcessSnapshot
    let rules: @Sendable () -> UserProtectionRules
    let guardPolicy: @Sendable () -> DeletionGuard
    let volumeSpace: @Sendable () -> VolumeSpaceSnapshot

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applications: [URL]? = nil,
        command: @escaping VirtualMachineCommand = { executable, arguments, timeout in
            try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        },
        executable: (@Sendable (VirtualMachineManager) -> String?)? = nil,
        activity: @escaping @Sendable () async throws -> DevProcessSnapshot = {
            try await DevProcessActivity.snapshot()
        },
        rules: @escaping @Sendable () -> UserProtectionRules = { .load() },
        guardPolicy: @escaping @Sendable () -> DeletionGuard = { .fromPreferences() },
        volumeSpace: @escaping @Sendable () -> VolumeSpaceSnapshot = { .capture(at: URL(fileURLWithPath: "/")) }
    ) {
        self.home = home
        self.applications =
            applications ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.command = command
        self.executable = executable ?? { Self.resolve($0, home: home) }
        self.activity = activity
        self.rules = rules
        self.guardPolicy = guardPolicy
        self.volumeSpace = volumeSpace
    }

    func scan() async -> VirtualMachineInventory {
        var result = await nativeInventory()
        let fileTask = Task.detached { VirtualMachineFiles(home: home, applications: applications).scan() }
        let files = await withTaskCancellationHandler(
            operation: { await fileTask.value }, onCancel: { fileTask.cancel() })
        result.installedManagers.formUnion(files.installedManagers)
        result.issues += files.issues
        for target in files.targets {
            if let index = result.targets.firstIndex(where: {
                $0.manager == target.manager && $0.paths.map(\.path) == target.paths.map(\.path)
            }) {
                result.targets[index].measuredBytes = target.measuredBytes
                result.targets[index].modified = target.modified
            } else {
                result.targets.append(target)
            }
        }
        for index in result.targets.indices where result.targets[index].measuredBytes == nil {
            let paths = result.targets[index].paths
            guard !paths.isEmpty else { continue }
            let task = Task.detached { try? VirtualMachineFiles.measure(paths) }
            let measured = await withTaskCancellationHandler(
                operation: { await task.value }, onCancel: { task.cancel() })
            result.targets[index].measuredBytes = measured?.bytes
            if let path = paths.first {
                result.targets[index].modified = try? path.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }
        }
        let safety = SafetyChecker(userRules: rules())
        do {
            let snapshot = try await activity()
            for index in result.targets.indices {
                let target = result.targets[index]
                do {
                    try Self.validateActivity(snapshot, target: target)
                    try Self.validateRules(safety, target: target)
                    if target.manager == .lima, target.retentionReason == nil {
                        result.targets[index] = try await verifiedLima(target, inventory: result, safety: safety)
                    }
                } catch { result.targets[index].retentionReason = error.localizedDescription }
            }
        } catch {
            result.issues.append("VM activity inspection unavailable.")
            for index in result.targets.indices {
                result.targets[index].retentionReason = "VM activity is unknown; retained."
            }
        }
        return result
    }

    func remove(_ targets: [VirtualMachineTarget], confirmed: Bool) async -> VirtualMachineReceipt {
        var removed: [String] = []
        var bytes: Int64 = 0
        var errors: [String] = []
        do { try preflight(targets, confirmed: confirmed) } catch {
            return VirtualMachineReceipt(
                removedIDs: [], processedTargetBytes: 0,
                errors: [error.localizedDescription], observation: nil)
        }
        let before = volumeSpace()
        for original in targets {
            do {
                try Task.checkCancellation()
                try preflight(targets, confirmed: true)
                let current = await scan()
                guard let target = current.targets.first(where: { $0.id == original.id }), target.canRemove,
                    target.evidence == original.evidence, target.nativeSignature == original.nativeSignature,
                    target.measuredBytes == original.measuredBytes, target.paths == original.paths,
                    let name = target.nativeName
                else {
                    throw VirtualMachineError(
                        "VM state, ownership, contents, protection or identity changed; retained.")
                }
                let policy = SafetyChecker(userRules: rules())
                try Self.validateRules(policy, target: target)
                try Self.validateActivity(try await activity(), target: target)
                let native = await nativeInventory()
                let verified = try await verifiedLima(target, inventory: native, safety: policy)
                guard verified.evidence == original.evidence else {
                    throw VirtualMachineError("VM files changed; retained.")
                }
                guard let tool = native.executablePaths[.lima] else {
                    throw VirtualMachineError("Lima CLI disappeared.")
                }
                let result = try await command(tool, ["--tty=false", "delete", name], 120)
                try result.checkedSuccess()
                let after = await nativeInventory()
                guard after.completeManagers.contains(.lima), !after.targets.contains(where: { $0.id == target.id })
                else {
                    throw VirtualMachineError("Native removal was not verified; refresh before retrying.")
                }
                removed.append(target.id)
                bytes += target.measuredBytes ?? 0
            } catch { errors.append("\(original.name): \(error.localizedDescription)") }
        }
        return VirtualMachineReceipt(
            removedIDs: removed, processedTargetBytes: bytes, errors: errors,
            observation: VolumeSpaceObservation(before: before, after: volumeSpace()))
    }

    private func nativeInventory() async -> VirtualMachineInventory {
        await VirtualMachineNative(home: home, command: command, executable: executable).scan()
    }

    private func preflight(_ targets: [VirtualMachineTarget], confirmed: Bool) throws {
        guard confirmed, !targets.isEmpty, Set(targets.map(\.id)).count == targets.count else {
            throw VirtualMachineError("Review unique eligible VM targets before removal.")
        }
        var total: Int64 = 0
        for target in targets {
            guard target.canRemove, let bytes = target.measuredBytes, bytes >= 0 else {
                throw VirtualMachineError("VM impact is unknown or a selected machine is retained.")
            }
            let (next, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { throw VirtualMachineError("Aggregate VM impact overflow.") }
            total = next
        }
        if case .blocked(let reason) = guardPolicy().classify(measuredTotalSize: total) {
            throw VirtualMachineError(reason)
        }
    }

    private func verifiedLima(
        _ original: VirtualMachineTarget, inventory: VirtualMachineInventory,
        safety: SafetyChecker
    ) async throws -> VirtualMachineTarget {
        guard inventory.completeManagers.contains(.lima),
            inventory.managerVersions[.lima] == "limactl version 2.2.1",
            let target = inventory.targets.first(where: { $0.id == original.id }), target.retentionReason == nil,
            target.nativeSignature == original.nativeSignature,
            inventory.targets.filter({ $0.manager == .lima }).allSatisfy({ $0.status == "Stopped" }),
            let tool = inventory.executablePaths[.lima], target.paths.count == 1
        else {
            throw VirtualMachineError("Complete stopped Lima 2.2.1 inventory and default-home ownership are required.")
        }
        let resolvedTool = URL(fileURLWithPath: tool).resolvingSymlinksInPath()
        let identity = try DevArtifactIdentity.read(resolvedTool)
        var executableStatus = stat()
        guard lstat(resolvedTool.path, &executableStatus) == 0 else {
            throw VirtualMachineError("CLI identity is unknown.")
        }
        let executableStamp = DevArtifactNode(path: resolvedTool.path, status: executableStatus)
        let task = Task.detached { try VirtualMachineFiles.measure(target.paths, safety: safety) }
        let measured = try await withTaskCancellationHandler(
            operation: { try await task.value }, onCancel: { task.cancel() })
        var value = target
        value.measuredBytes = measured.bytes
        value.evidence = VirtualMachineEvidence(
            roots: measured.identities, nodes: measured.nodes,
            executablePath: resolvedTool.path, executableIdentity: identity, executableStamp: executableStamp,
            ownerUID: getuid())
        return value
    }

    private static func validateRules(_ safety: SafetyChecker, target: VirtualMachineTarget) throws {
        for path in target.paths {
            if let result = safety.validateUserRules(path.path, mode: .cleanup), !result.isSafe {
                throw VirtualMachineError(result.reason ?? "Protected VM retained.")
            }
        }
    }

    private static func validateActivity(_ snapshot: DevProcessSnapshot, target: VirtualMachineTarget) throws {
        guard snapshot.issues.isEmpty else {
            throw VirtualMachineError("VM process inspection is incomplete; retained.")
        }
        for path in target.paths where !snapshot.blockers(target: path, project: path).isEmpty {
            throw VirtualMachineError("VM storage is in use; retained.")
        }
        if target.manager == .lima,
            snapshot.jobs.contains(where: {
                $0.name.hasPrefix("qemu-system") || ["limactl", "lima", "colima"].contains($0.name)
            }) {
            throw VirtualMachineError("VM manager or hypervisor activity is present; retained.")
        }
    }

    private static func resolve(_ manager: VirtualMachineManager, home: URL) -> String? {
        guard let name = manager.executableName else { return nil }
        if let tool = HomebrewPaths.toolPath(name), FileManager.default.isExecutableFile(atPath: tool) { return tool }
        let bundled: [VirtualMachineManager: String] = [
            .orbStack: "/Applications/OrbStack.app/Contents/MacOS/bin/orb",
            .utm: "/Applications/UTM.app/Contents/MacOS/utmctl",
            .parallels: "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl",
            .virtualBox: "/Applications/VirtualBox.app/Contents/MacOS/VBoxManage",
            .vagrant: "/opt/vagrant/bin/vagrant"
        ]
        if manager == .orbStack {
            let tool = home.appendingPathComponent(".orbstack/bin/orb").path
            if FileManager.default.isExecutableFile(atPath: tool) { return tool }
        }
        guard let tool = bundled[manager], FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        return tool
    }
}
