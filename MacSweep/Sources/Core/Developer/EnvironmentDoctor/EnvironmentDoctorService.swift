import Darwin
import Foundation

struct EnvironmentDoctorService: Sendable {
    var paths = DoctorPaths()
    var command: DoctorCommandRunner = { executable, arguments, timeout in
        try await ProcessRunner.run(
            executable: executable, arguments: arguments,
            currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
    }
    var rules: @Sendable () -> UserProtectionRules = { .load() }
    var trash: @Sendable (URL) throws -> Void = { try CleanupFileRemover.recoverable($0, module: "environment-doctor") }
    var privilegedTrash: (@Sendable (DoctorFinding) async throws -> Void)?

    func scan() async -> DoctorInventory {
        let checker = SafetyChecker(userRules: rules())
        var result: DoctorInventory
        do { result = try await DevArtifactIO.run { try DoctorFileChecks.scan(paths, checker: checker) } } catch {
            result = DoctorInventory(issues: [error.localizedDescription])
        }
        async let pathResult = DoctorCommandChecks.loginPath(paths: paths, command: command)
        async let brewResult = DoctorCommandChecks.homebrew(paths: paths, command: command)
        let checks = await [pathResult, brewResult]
        for check in checks {
            result.findings += check.findings
            result.issues += check.issues
        }
        for index in result.findings.indices where result.findings[index].requiresAdministrator {
            if privilegedTrash == nil {
                result.findings[index].retentionReason =
                    "Administrator repair is unavailable; use the copyable instructions."
            } else if !PrivilegedRunner.doctorAdministratorRepairIsSupported(result.findings[index]) {
                result.findings[index].retentionReason =
                    "This system repair requires manual review; use the copyable instructions."
            }
        }
        return result
    }

    func repair(
        _ selected: [DoctorFinding], confirmed: Bool, administratorAcknowledged: Bool,
        guard deletionGuard: DeletionGuard = .fromPreferences()
    ) async -> CleanupResult {
        let previews = selected.compactMap(\.preview)
        let impact = previews.reduce(Int64(0)) { total, item in
            let value = total.addingReportingOverflow(item.size)
            return value.overflow ? Int64.max : value.partialValue
        }
        guard confirmed, Set(selected.map(\.id)).count == selected.count else {
            return failure(selected, "Review unique findings before repair.")
        }
        if case .blocked(let reason) = deletionGuard.classify(measuredTotalSize: impact) {
            return failure(selected, reason)
        }
        guard !selected.contains(where: \.requiresAdministrator) || administratorAcknowledged else {
            return failure(selected, "Acknowledge administrator authorization before starting.")
        }
        var processed = 0
        var processedBytes: Int64 = 0
        var actions: [UUID: CleanupHistoryAction] = [:]
        var errors: [CleanupError] = []
        for original in selected {
            do {
                let fresh = try validated(original)
                try await dispatch(fresh, administratorAcknowledged: administratorAcknowledged)
                processed += 1
                processedBytes += max(0, original.stamp?.size ?? 0)
                actions[original.reviewID] = .moveToTrash
            } catch {
                errors.append(
                    CleanupError(
                        path: original.path ?? URL(fileURLWithPath: "/"),
                        message: error.localizedDescription))
            }
        }
        // This field is a target-size estimate. Accounting identifies Trash
        // disposition and does not claim that the volume gained this space.
        return CleanupResult(
            itemsProcessed: processed, bytesFreed: processedBytes, errors: errors,
            historyActions: actions
        ).accounting(for: previews)
    }

    private func validated(_ original: DoctorFinding) throws -> DoctorFinding {
        try Task.checkCancellation()
        guard original.canRepair, let path = original.path,
            paths.launchDirectories.contains(where: {
                $0.standardizedFileURL.path == path.deletingLastPathComponent().standardizedFileURL.path
            })
                || paths.binDirectories.contains(where: {
                    $0.standardizedFileURL.path == path.deletingLastPathComponent().standardizedFileURL.path
                })
        else {
            throw DevArtifactSafetyError("Finding is retained or outside supported repair roots.")
        }
        let checker = SafetyChecker(userRules: rules())
        let validation = checker.validateForDoctorRepair(original, paths: paths)
        guard validation.isSafe else { throw DevArtifactSafetyError(validation.reason ?? "Repair retained.") }
        let fresh: DoctorFinding?
        switch original.repair {
        case .orphanedLaunchItem: fresh = try DoctorFileChecks.launchItem(path, home: paths.home)
        case .brokenLink: fresh = try DoctorFileChecks.brokenLink(path)
        case nil: fresh = nil
        }
        guard let fresh, fresh.repair == original.repair, fresh.stamp == original.stamp,
            path.deletingLastPathComponent().standardizedFileURL.path
                == path.deletingLastPathComponent().resolvingSymlinksInPath().path
        else { throw DevArtifactSafetyError("Finding changed. Rescan and review again.") }
        return fresh
    }

    private func dispatch(_ fresh: DoctorFinding, administratorAcknowledged: Bool) async throws {
        guard let path = fresh.path else { throw DevArtifactSafetyError("No repair path.") }
        if fresh.requiresAdministrator {
            guard administratorAcknowledged else {
                throw DevArtifactSafetyError(
                    "Privilege requirements changed. Review administrator authorization first.")
            }
            guard let privilegedTrash else { throw DevArtifactSafetyError("Administrator repair unavailable.") }
            try await privilegedTrash(fresh)
        } else {
            // A final symlink is the selected broken link itself; never resolve its target for Trash.
            guard fresh.repair != nil else { throw DevArtifactSafetyError("No exact repair is available.") }
            try trash(path)
        }
        var remaining = stat()
        guard lstat(path.path, &remaining) != 0, errno == ENOENT else {
            throw DevArtifactSafetyError("Trash operation was not verified.")
        }
    }

    private func failure(_ findings: [DoctorFinding], _ message: String) -> CleanupResult {
        CleanupResult(
            itemsProcessed: 0, bytesFreed: 0,
            errors: findings.map {
                CleanupError(path: $0.path ?? URL(fileURLWithPath: "/"), message: message)
            })
    }
}
