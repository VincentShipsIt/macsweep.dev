import Foundation

struct LocalSnapshotService {
    let command: LocalSnapshotCommand
    let privileged: @Sendable (LocalSnapshotThinningTarget) async throws -> Void
    let permissions: @Sendable () -> LocalSnapshotPermissions
    let capacity: @Sendable () -> LocalSnapshotCapacity
    let rules: @Sendable () -> UserProtectionRules
    let guardPolicy: @Sendable () -> DeletionGuard

    init(
        command: @escaping LocalSnapshotCommand = { executable, arguments, timeout in
            try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        },
        privileged: @escaping @Sendable (LocalSnapshotThinningTarget) async throws -> Void = { target in
            try await PrivilegedRunner.runShellScriptAsAdmin(target.trustedScript, timeout: 180)
        },
        permissions: @escaping @Sendable () -> LocalSnapshotPermissions = { .current() },
        capacity: @escaping @Sendable () -> LocalSnapshotCapacity = { .capture() },
        rules: @escaping @Sendable () -> UserProtectionRules = { .load() },
        guardPolicy: @escaping @Sendable () -> DeletionGuard = { .fromPreferences() }
    ) {
        self.command = command
        self.privileged = privileged
        self.permissions = permissions
        self.capacity = capacity
        self.rules = rules
        self.guardPolicy = guardPolicy
    }

    func scan() async -> LocalSnapshotInventory {
        var result = LocalSnapshotInventory()
        result.permissions = permissions()
        result.capacity = capacity()
        do {
            let help = try await read("/usr/bin/tmutil", ["help", "thinlocalsnapshots"], help: true)
            guard help.contains("tmutil thinlocalsnapshots <mount_point> [purgeamount] [urgency]") else {
                throw LocalSnapshotError("Installed Time Machine thinning interface is unsupported.")
            }
            result.volumeID = try LocalSnapshotParsing.volume(
                try await read("/usr/sbin/diskutil", ["info", "-plist", "/"]))
            result.snapshots = try LocalSnapshotParsing.snapshots(
                try await read("/usr/bin/tmutil", ["listlocalsnapshots", "/"]))
            result.isBackupRunning = try LocalSnapshotParsing.backupRunning(
                try await read("/usr/bin/tmutil", ["status"]))
            try validateRules(result.snapshots)
            result.nativeSupported = true
        } catch { result.issues.append(error.localizedDescription) }
        return result
    }

    func thin(
        _ target: LocalSnapshotThinningTarget, reviewed: LocalSnapshotInventory,
        confirmed: Bool
    ) async -> LocalSnapshotReceipt {
        var completed = false
        var before: LocalSnapshotCapacity?
        do {
            try Task.checkCancellation()
            guard confirmed, reviewed.canThin else {
                throw LocalSnapshotError("Review an eligible snapshot inventory before thinning.")
            }
            let fresh = await scan()
            guard fresh.canThin, fresh.volumeID == reviewed.volumeID, fresh.snapshots == reviewed.snapshots else {
                throw LocalSnapshotError("Snapshot set, volume, permissions or backup activity changed. Review again.")
            }
            if case .blocked(let reason) = guardPolicy().classify(measuredTotalSize: target.rawValue) {
                throw LocalSnapshotError(reason)
            }
            try validateRules(fresh.snapshots)
            guard permissions().blocker == nil else {
                throw LocalSnapshotError("Full Disk Access or administrator authorization is no longer available.")
            }
            before = capacity()
            try Task.checkCancellation()
            try await privileged(target)
            completed = true
            let after = await scan()
            guard after.nativeSupported, after.volumeID == fresh.volumeID else {
                throw LocalSnapshotError("Thinning returned, but the resulting snapshot inventory is unverified.")
            }
            let missing = Set(fresh.snapshots.map(\.id)).subtracting(after.snapshots.map(\.id)).sorted()
            return receipt(completed: true, missing: missing, before: before, after: after.capacity, errors: [])
        } catch {
            return receipt(
                completed: completed, missing: [], before: before, after: before == nil ? nil : capacity(),
                errors: [error.localizedDescription])
        }
    }

    func requestBlocker(_ target: LocalSnapshotThinningTarget) -> String? {
        if case .blocked(let reason) = guardPolicy().classify(measuredTotalSize: target.rawValue) { return reason }
        return nil
    }

    private func receipt(
        completed: Bool, missing: [String], before: LocalSnapshotCapacity?,
        after: LocalSnapshotCapacity?, errors: [String]
    ) -> LocalSnapshotReceipt {
        let observation: VolumeSpaceObservation?
        if let before, let after {
            observation = VolumeSpaceObservation(before: before.available, after: after.available)
        } else {
            observation = nil
        }
        return LocalSnapshotReceipt(
            commandCompleted: completed, observedMissingIDs: missing, observation: observation,
            beforeReclaimable: before?.reclaimableEstimate,
            afterReclaimable: after?.reclaimableEstimate, errors: errors)
    }

    private func validateRules(_ snapshots: [LocalTimeMachineSnapshot]) throws {
        let checker = SafetyChecker(userRules: rules())
        let paths =
            ["/", "/System/Volumes/Data", "/Volumes/com.apple.TimeMachine.localsnapshots"]
            + snapshots.map(\.protectionPath)
        for path in paths {
            if let result = checker.validateUserRules(path, mode: .cleanup), !result.isSafe {
                throw LocalSnapshotError(result.reason ?? "Snapshot or volume is protected.")
            }
        }
    }

    private func read(_ executable: String, _ arguments: [String], help: Bool = false) async throws -> String {
        try Task.checkCancellation()
        let result = try await command(executable, arguments, 20)
        try result.checkedSuccess()
        guard help || result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalSnapshotError("Native diagnostics prevented a complete snapshot inventory.")
        }
        let output = help ? result.output + result.error : result.output
        guard result.outputWasValidUTF8, output.utf8.count <= 1_048_576 else {
            throw LocalSnapshotError("Time Machine output is incomplete or oversized.")
        }
        return output
    }
}
