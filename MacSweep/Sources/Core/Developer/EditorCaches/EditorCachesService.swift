import Darwin
import Foundation

struct EditorCachesService {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var applications: () async -> EditorApplicationInventory = { await EditorApplicationDiscovery.inventory() }
    var activity: () async -> DevProcessSnapshot = {
        (try? await DevProcessActivity.snapshot()) ?? DevProcessSnapshot(issues: ["Activity inspection unavailable."])
    }
    var protectionRules: () -> SafetyChecker = { SafetyChecker() }
    var trash: (URL) throws -> Void = { try CleanupFileRemover.recoverable($0, module: "editor-caches") }
    var deletionGuard = DeletionGuard.fromPreferences()
    private var canonicalHome: URL { EditorCacheMatchers.canonical(home) }

    func scan() async -> EditorCachesReport {
        guard !Task.isCancelled else { return EditorCachesReport(issues: ["Scan cancelled; rescan required."]) }
        let apps = await applications()
        let processes = await activity()
        let checker = protectionRules()
        do {
            return try await DevArtifactIO.run {
                var discovery = EditorCacheDiscovery(home: canonicalHome, applications: apps, checker: checker)
                let candidates = discovery.candidates()
                var report = EditorCachesReport(issues: Array(Set(apps.issues + discovery.issues)).sorted())
                let deadline = ProcessInfo.processInfo.systemUptime + 12
                for candidate in candidates {
                    guard report.findings.count < 4000, ProcessInfo.processInfo.systemUptime < deadline,
                        !Task.isCancelled
                    else {
                        report.issues.append("Editor cache inspection exceeded its budget or was cancelled.")
                        break
                    }
                    report.findings.append(
                        inspect(
                            candidate, apps: apps, processes: processes,
                            checker: checker, incomplete: !report.issues.isEmpty))
                }
                if !report.issues.isEmpty {
                    report.findings = report.findings.map { finding in
                        EditorCacheFinding(
                            candidate: finding.candidate, identity: finding.identity, nodes: finding.nodes,
                            modified: finding.modified, size: finding.size,
                            retentionReason: "Inventory incomplete; resolve the reported gaps and rescan.")
                    }
                }
                report.findings.sort { $0.id < $1.id }
                return report
            }
        } catch {
            return EditorCachesReport(issues: ["Scan cancelled or disk work unavailable; rescan required."])
        }
    }

    private func inspect(
        _ candidate: EditorCacheCandidate, apps: EditorApplicationInventory,
        processes: DevProcessSnapshot, checker: SafetyChecker, incomplete: Bool
    ) -> EditorCacheFinding {
        var reason = candidate.retentionReason
        let running = Set(apps.runningIDs.map { $0.lowercased() })
        if candidate.ownerIDs.contains(where: { owner in
            running.contains {
                $0 == owner.lowercased()
                    || $0.hasPrefix(owner.lowercased() + ".")
            }
        }) {
            reason = "Owning app is running; quit it and rescan."
        }
        if candidate.kind == .jetBrains, running.contains(where: EditorApplicationDiscovery.isJetBrainsProcess) {
            reason = "A JetBrains app is running; all IDE caches retained."
        }
        let blockers = ManagedCleanupEvidence.blockers(processes, path: candidate.path)
        reason = ManagedCleanupEvidence.activityReason(processes, blockers: blockers) ?? reason
        if incomplete { reason = "Installed application or cache inventory incomplete." }
        var nodes: [DevArtifactNode] = []
        if reason == nil {
            do { nodes = try EditorCacheEvidence.nodes(candidate, home: canonicalHome, checker: checker) } catch {
                reason = error.localizedDescription
            }
        }
        let modified =
            nodes.map { Date(timeIntervalSince1970: Double($0.modifiedSeconds)) }.max()
            ?? (try? candidate.path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let bytes = nodes.filter { $0.mode & S_IFMT == S_IFREG }.reduce(Int64(0)) { $0 + Int64(max(0, $1.size)) }
        return EditorCacheFinding(
            candidate: candidate, identity: try? ManagedCleanupEvidence.identity(candidate.path),
            nodes: nodes, modified: modified, size: bytes, retentionReason: reason)
    }

    func remove(_ submitted: [EditorCacheFinding]) async -> CleanupResult {
        let selected = Dictionary(submitted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let items = selected.map(\.cleanupItem)
        if case .blocked(let reason) = deletionGuard.preflightCheck(items: items) {
            return CleanupResult(
                itemsProcessed: 0, bytesFreed: 0,
                errors: selected.map { CleanupError(path: $0.candidate.path, message: reason, underlyingError: nil) })
        }
        var processed = 0
        var moved: Int64 = 0
        var errors: [CleanupError] = []
        for finding in selected {
            do {
                try Task.checkCancellation()
                guard finding.isSelectable else { throw DevArtifactSafetyError("Target is retained; rescan first.") }
                let report = await scan()
                guard let fresh = report.findings.first(where: { $0.id == finding.id }), fresh.isSelectable,
                    fresh.candidate.kind == finding.candidate.kind,
                    fresh.candidate.evidence == finding.candidate.evidence,
                    fresh.identity == finding.identity, fresh.nodes == finding.nodes
                else {
                    throw DevArtifactSafetyError(
                        "App, workspace, extension, activity or content changed; rescan first.")
                }
                let processes = await activity()
                let blockers = ManagedCleanupEvidence.blockers(processes, path: finding.candidate.path)
                if let reason = ManagedCleanupEvidence.activityReason(processes, blockers: blockers) {
                    throw DevArtifactSafetyError(reason)
                }
                try Task.checkCancellation()
                try moveToTrash(finding)
                processed += 1
                moved += finding.size
            } catch {
                errors.append(
                    CleanupError(
                        path: finding.candidate.path, message: error.localizedDescription, underlyingError: nil))
            }
        }
        return CleanupResult(
            itemsProcessed: processed, bytesFreed: 0, errors: errors,
            accounting: CleanupAccounting(
                estimatedTargetBytes: items.estimatedBytes,
                estimatedProcessedBytes: moved, movedToTrashBytes: moved, permanentlyRemovedTargetBytes: 0,
                removedLocalCopyBytes: 0, toolProcessedBytes: 0, volumeObservations: []))
    }
    private func moveToTrash(_ finding: EditorCacheFinding) throws {
        guard try ManagedCleanupEvidence.identity(finding.candidate.path) == finding.identity,
            try EditorCacheEvidence.nodes(finding.candidate, home: canonicalHome, checker: protectionRules())
                == finding.nodes
        else {
            throw DevArtifactSafetyError("Identity or content changed before Trash dispatch.")
        }
        try trash(finding.candidate.path)
        var remaining = stat()
        guard lstat(finding.candidate.path.path, &remaining) != 0, errno == ENOENT else {
            throw DevArtifactSafetyError("Trash did not remove the source target; no success credited.")
        }
    }

}
