import Foundation

struct XcodeCleanupService {
    let home: URL
    let applications: [URL]
    let systemCaches: URL?
    let command: XcodeCommand
    let activity: @Sendable () async throws -> DevProcessSnapshot
    let rules: @Sendable () -> UserProtectionRules
    let trash: @Sendable (URL) throws -> Void
    let now: @Sendable () -> Date
    let deletionGuard: DeletionGuard
    let volumeSpace: @Sendable () -> VolumeSpaceSnapshot

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        applications: [URL]? = nil,
        systemCaches: URL? = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches"),
        command: @escaping XcodeCommand = { executable, arguments, timeout in
            try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        },
        activity: @escaping @Sendable () async throws -> DevProcessSnapshot = {
            try await DevProcessActivity.snapshot()
        },
        rules: @escaping @Sendable () -> UserProtectionRules = { .load() },
        trash: @escaping @Sendable (URL) throws -> Void = {
            try CleanupFileRemover.recoverable($0, module: "xcode-cleanup")
        },
        now: @escaping @Sendable () -> Date = { Date() },
        deletionGuard: DeletionGuard = .fromPreferences(),
        volumeSpace: @escaping @Sendable () -> VolumeSpaceSnapshot = { .capture(at: URL(fileURLWithPath: "/")) }
    ) {
        self.home = home
        self.applications =
            applications ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        self.systemCaches = systemCaches
        self.command = command
        self.activity = activity
        self.rules = rules
        self.trash = trash
        self.now = now
        self.deletionGuard = deletionGuard
        self.volumeSpace = volumeSpace
    }

    func scan() async -> XcodeCleanupInventory {
        let safety = SafetyChecker(userRules: rules())
        var result = await XcodeCleanupNative(home: home, safety: safety, command: command).scan()
        let selectedDeveloper = result.selectedDeveloper
        let fileInventory: XcodeCleanupInventory
        do {
            fileInventory = try await DevArtifactIO.run {
                XcodeCleanupFiles(
                    home: home, applications: applications, now: now(), safety: safety, systemCaches: systemCaches
                ).scan(selectedDeveloper: selectedDeveloper)
            }
        } catch {
            result.issues.append("Xcode file inspection incomplete: \(error.localizedDescription)")
            for index in result.targets.indices {
                result.targets[index].retentionReason = "Inspection incomplete; rescan."
            }
            return result
        }
        result.targets += fileInventory.targets
        result.issues += fileInventory.issues
        do {
            let snapshot = try await activity()
            for index in result.targets.indices {
                if let reason = Self.activityReason(snapshot, target: result.targets[index]) {
                    result.targets[index].retentionReason = reason
                }
            }
        } catch {
            result.issues.append("Developer activity could not be inspected.")
            for index in result.targets.indices {
                result.targets[index].retentionReason = "Activity is unknown; retained."
            }
        }
        return result
    }

    /// The caller has completed the shared cleanup review. Every dispatch is
    /// re-inventoried; only the exact unchanged target can be acted on.
    func remove(_ selected: [XcodeCleanupTarget], confirmed: Bool) async -> XcodeCleanupReceipt {
        var removed: [String] = []
        var failures: [String] = []
        var removedTargetBytes: Int64 = 0
        var trashedBytes: Int64 = 0
        var authorizedBytes: Int64 = 0
        guard confirmed, Set(selected.map(\.id)).count == selected.count else {
            return XcodeCleanupReceipt(
                removedIDs: [], errors: ["Explicit review of unique targets is required."],
                removedTargetBytes: 0, observation: nil, trashedBytes: 0)
        }
        do {
            try preflightSelection(selected)
        } catch {
            return XcodeCleanupReceipt(
                removedIDs: [], errors: [error.localizedDescription],
                removedTargetBytes: 0, observation: nil, trashedBytes: 0)
        }
        let before = volumeSpace()
        for original in selected {
            do {
                let target = try await refreshed(original)
                let bytes = target.bytes ?? 0
                let total = try authorize(bytes, alreadyAuthorized: authorizedBytes)
                try await dispatch(target)
                authorizedBytes = total
                if target.mechanism == .trash {
                    trashedBytes += bytes
                } else {
                    let verified = await scan()
                    guard verified.nativeCommandsAvailable,
                        !verified.targets.contains(where: { $0.id == target.id })
                    else {
                        throw XcodeCleanupError("Native deletion was not verified. Refresh before retrying.")
                    }
                    removedTargetBytes += bytes
                }
                removed.append(target.id)
            } catch {
                failures.append("\(original.name): \(error.localizedDescription)")
            }
        }
        return XcodeCleanupReceipt(
            removedIDs: removed, errors: failures,
            removedTargetBytes: removedTargetBytes,
            observation: VolumeSpaceObservation(before: before, after: volumeSpace()), trashedBytes: trashedBytes)
    }

    private func preflightSelection(_ selected: [XcodeCleanupTarget]) throws {
        var total: Int64 = 0
        for target in selected {
            guard target.canRemove, let bytes = target.bytes, bytes >= 0 else {
                throw XcodeCleanupError("Every selected target needs complete eligible size evidence.")
            }
            total = try authorize(bytes, alreadyAuthorized: total)
        }
    }

    private func refreshed(_ original: XcodeCleanupTarget) async throws -> XcodeCleanupTarget {
        try Task.checkCancellation()
        let current = await scan()
        guard let target = current.targets.first(where: { $0.id == original.id }), original.canRemove,
            target.canRemove, target.evidence == original.evidence, target.bytes == original.bytes,
            target.mechanism == original.mechanism, target.path == original.path
        else {
            throw XcodeCleanupError("Target changed, is active, or is retained. Rescan and review again.")
        }
        return target
    }

    private func authorize(_ bytes: Int64, alreadyAuthorized: Int64) throws -> Int64 {
        let (total, overflow) = alreadyAuthorized.addingReportingOverflow(bytes)
        guard !overflow else { throw XcodeCleanupError("Cleanup size overflow.") }
        if case .blocked(let reason) = deletionGuard.classify(measuredTotalSize: total) {
            throw XcodeCleanupError(reason)
        }
        return total
    }

    private func dispatch(_ target: XcodeCleanupTarget) async throws {
        let safety = SafetyChecker(userRules: rules())
        if let validation = safety.validateUserRules(target.path.path, mode: .cleanup), !validation.isSafe {
            throw XcodeCleanupError(validation.reason ?? "Protected target retained.")
        }
        let snapshot = try await activity()
        if let reason = Self.activityReason(snapshot, target: target) { throw XcodeCleanupError(reason) }
        try Task.checkCancellation()
        switch target.mechanism {
        case .runtime(let id):
            try await validateNativeDispatch(target, safety: safety)
            let result = try await command("/usr/bin/xcrun", ["simctl", "runtime", "delete", id.uuidString], 120)
            try result.checkedSuccess()
        case .simulator(let id):
            try await validateNativeDispatch(target, safety: safety)
            let result = try await command("/usr/bin/xcrun", ["simctl", "delete", id.uuidString], 120)
            try result.checkedSuccess()
        case .trash:
            let fresh = try await fileEvidence(target, safety: safety)
            guard fresh == target.evidence else { throw XcodeCleanupError("Contents changed; retained.") }
            try Task.checkCancellation()
            try trash(target.path)
            guard !FileManager.default.fileExists(atPath: target.path.path) else {
                throw XcodeCleanupError("Trash operation was not verified; refresh before retrying.")
            }
        }
    }

    private func validateNativeDispatch(_ target: XcodeCleanupTarget, safety: SafetyChecker) async throws {
        let native = await XcodeCleanupNative(home: home, safety: safety, command: command).scan()
        guard native.nativeCommandsAvailable,
            let current = native.targets.first(where: { $0.id == target.id }), current.canRemove,
            current.evidence == target.evidence, current.bytes == target.bytes,
            current.path == target.path, current.mechanism == target.mechanism
        else {
            throw XcodeCleanupError("Native target or global simulator activity changed before dispatch; retained.")
        }
        try Task.checkCancellation()
    }

    private func fileEvidence(
        _ target: XcodeCleanupTarget, safety: SafetyChecker
    ) async throws -> XcodeCleanupEvidence {
        return try await DevArtifactIO.run {
            try XcodeCleanupFiles.measure(
                target.path, safety: safety,
                appBundle: target.category == .applications
            ).evidence
        }
    }

    private static func activityReason(_ snapshot: DevProcessSnapshot, target: XcodeCleanupTarget) -> String? {
        guard snapshot.issues.isEmpty else { return "Developer activity inspection is incomplete; retained." }
        let activeNames = Set([
            "Xcode", "xcodebuild", "Simulator", "SimulatorTrampoline", "swift-frontend",
            "swiftc", "clang", "clang++", "IBAgent-iOS", "XCPreviewAgent"
        ])
        if snapshot.jobs.contains(where: { activeNames.contains($0.name) }) {
            return "Xcode, Simulator, preview or compiler activity is present; retained."
        }
        let blockers = snapshot.blockers(target: target.path, project: target.path)
        return blockers.isEmpty ? nil : "Target is in use by \(blockers.map(\.label).joined(separator: ", "))."
    }
}
