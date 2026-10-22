import Darwin
import Foundation

struct OrphanedAppDataService {
    var library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
    var ownership: () async -> AppOwnershipInventory = { await AppOwnershipDiscovery.inventory() }
    var activity: () async -> DevProcessSnapshot = {
        (try? await DevProcessActivity.snapshot()) ?? DevProcessSnapshot(issues: ["Activity inspection unavailable."])
    }
    var protectionRules: () -> SafetyChecker = { SafetyChecker() }
    private var checker: SafetyChecker { protectionRules() }
    var registeredOwner: (String) -> Bool = AppOwnershipDiscovery.hasRegisteredOwner
    private func rootIsSafe(_ path: URL) -> Bool {
        checker.validateForUninstallLeftover(path, libraryDirectory: library).isSafe
    }
    var trash: (URL) throws -> Void = { try CleanupFileRemover.recoverable($0, module: "app-leftovers") }
    var now: () -> Date = Date.init
    var deletionGuard = DeletionGuard.fromPreferences()

    func scan() async -> AppLeftoversReport {
        guard !Task.isCancelled else { return AppLeftoversReport(issues: ["Scan cancelled; rescan required."]) }
        let installed = await ownership()
        let processes = await activity()
        let inspection = Task.detached(priority: .utility) { inspect(installed, activity: processes) }
        return await withTaskCancellationHandler {
            await inspection.value
        } onCancel: {
            inspection.cancel()
        }
    }

    private func inspect(_ inventory: AppOwnershipInventory, activity: DevProcessSnapshot) -> AppLeftoversReport {
        var report = AppLeftoversReport(issues: inventory.issues)
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        let paths = libraryPaths(issues: &report.issues)
        let owners = containerOwners(paths, deadline: deadline, issues: &report.issues)
        for (path, category) in paths {
            guard report.findings.count < 4000, ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled
            else {
                report.issues.append("Library inspection exceeded its budget or was cancelled; rescan required.")
                break
            }
            if let finding = finding(
                path, category: category, owners: owners, inventory: inventory, activity: activity
            ) {
                report.findings.append(finding)
            }
        }
        report.issues = Array(Set(report.issues)).sorted()
        if !report.issues.isEmpty {
            report.findings = report.findings.map { $0.retaining("Inventory incomplete; every finding retained.") }
        }
        report.findings.sort { $0.path.path < $1.path.path }
        return report
    }

    private func libraryPaths(issues: inout [String]) -> [(URL, String)] {
        var paths: [(URL, String)] = []
        for category in AppLeftoversInspection.categories {
            let root = library.appending(path: category)
            var metadata = stat()
            if lstat(root.path, &metadata) != 0 {
                if errno != ENOENT { issues.append("\(category) access unavailable; all findings retained.") }
                continue
            }
            do {
                let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                guard children.count <= 20_000 else { throw DevArtifactSafetyError("Library entry limit exceeded.") }
                paths.append(contentsOf: children.map { ($0, category) })
            } catch { issues.append("\(category) inventory incomplete; all findings retained.") }
        }
        return paths
    }

    private func containerOwners(
        _ paths: [(URL, String)], deadline: TimeInterval, issues: inout [String]
    ) -> Set<String> {
        var owners = Set<String>()
        for (path, category) in paths where category == "Containers" {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                issues.append("Container ownership inspection exceeded its budget; all findings retained.")
                break
            }
            if let owner = AppLeftoversInspection.containerOwner(path) { owners.insert(owner) }
        }
        return owners
    }

    private func finding(
        _ path: URL, category: String, owners: Set<String>,
        inventory: AppOwnershipInventory, activity: DevProcessSnapshot
    ) -> OrphanedAppData? {
        if inventory.installedNames.contains(path.deletingPathExtension().lastPathComponent.lowercased()) {
            return nil
        }
        let identifier = AppLeftoversInspection.guessedIdentifier(path)
        if let identifier,
            inventory.installed.contains(identifier) || inventory.running.contains(identifier) {
            return nil
        }
        let grounded = identifier.map { owners.contains($0) } == true && category != "Group Containers"
        if grounded, let identifier, registeredOwner(identifier) { return nil }
        var reason: String?
        let identity = try? ManagedCleanupEvidence.identity(path)
        var nodes: [DevArtifactNode] = []
        if grounded {
            do { nodes = try AppLeftoversInspection.nodes(path, checker: checker, library: library) } catch {
                reason = error.localizedDescription
            }
        }
        let modified =
            nodes.map { Date(timeIntervalSince1970: Double($0.modifiedSeconds)) }.max()
            ?? (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let size = nodes.filter { $0.mode & S_IFMT == S_IFREG }.reduce(Int64(0)) { $0 + max(0, Int64($1.size)) }
        reason = ownershipReason(identifier, grounded: grounded, category: category, inventory: inventory) ?? reason
        if modified.map({ $0 > now().addingTimeInterval(-30 * 86_400) }) ?? true {
            reason = "Modified within 30 days, or modification metadata unavailable."
        }
        if !rootIsSafe(path) { reason = "Protected path or unsupported app-data scope." }
        let blockers = ManagedCleanupEvidence.blockers(activity, path: path)
        reason = ManagedCleanupEvidence.activityReason(activity, blockers: blockers) ?? reason
        let evidence =
            grounded
            ? "Container Manager metadata establishes \(identifier ?? "unknown") ownership; "
                + "no matching installed or running app was found."
            : "Name suggests \(identifier ?? path.lastPathComponent); owning application cannot be established."
        return OrphanedAppData(
            path: path, identifier: identifier, category: category,
            size: size, modified: modified, confidence: grounded ? .grounded : .uncertain,
            evidence: evidence, retentionReason: reason, nodes: nodes, identity: identity)
    }

    private func ownershipReason(
        _ identifier: String?, grounded: Bool, category: String, inventory: AppOwnershipInventory
    ) -> String? {
        if category == "Group Containers" {
            return "Shared container membership is unknown; retained for all entitled apps."
        }
        guard grounded, let identifier else {
            return "No independent app ownership record; filename matching is insufficient."
        }
        if identifier.hasPrefix("com.apple.") { return "Apple system and built-in application data retained." }
        let vendor = identifier.split(separator: ".").prefix(2).joined(separator: ".") + "."
        if inventory.installed.union(inventory.running).contains(where: { $0.hasPrefix(vendor) }) {
            return "An app from this identifier's vendor is installed or running; shared data retained."
        }
        return nil
    }

    /// Confirmation does not turn old inventory into authority: every dispatch rescans all retention evidence.
    func remove(_ submitted: [OrphanedAppData]) async -> CleanupResult {
        let unique = Dictionary(submitted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted {
            if ($0.category == "Containers") != ($1.category == "Containers") { return $1.category == "Containers" }
            return $0.id < $1.id
        }
        var processed = 0
        var movedBytes: Int64 = 0
        var errors: [CleanupError] = []
        let items = unique.map(\.cleanupItem)
        if case .blocked(let reason) = deletionGuard.preflightCheck(items: items) {
            return CleanupResult(
                itemsProcessed: 0, bytesFreed: 0,
                errors: unique.map { CleanupError(path: $0.path, message: reason, underlyingError: nil) })
        }
        for old in unique {
            do {
                try Task.checkCancellation()
                guard old.isSelectable else { throw DevArtifactSafetyError("Finding is retained; rescan first.") }
                let fresh = await scan()
                guard let current = fresh.findings.first(where: { $0.id == old.id }), current.isSelectable,
                    current.identifier == old.identifier, current.identity == old.identity, current.nodes == old.nodes
                else {
                    throw DevArtifactSafetyError("Ownership, activity, identity or content changed; rescan first.")
                }
                try Task.checkCancellation()
                let latestActivity = await activity()
                let blockers = ManagedCleanupEvidence.blockers(latestActivity, path: old.path)
                if let reason = ManagedCleanupEvidence.activityReason(latestActivity, blockers: blockers) {
                    throw DevArtifactSafetyError(reason)
                }
                try moveToTrash(old)
                processed += 1
                movedBytes += old.size
            } catch {
                errors.append(CleanupError(path: old.path, message: error.localizedDescription, underlyingError: nil))
            }
        }
        // A recoverable Trash move does not release disk space.
        return CleanupResult(
            itemsProcessed: processed, bytesFreed: 0, errors: errors,
            accounting: CleanupAccounting(
                estimatedTargetBytes: items.estimatedBytes,
                estimatedProcessedBytes: movedBytes, movedToTrashBytes: movedBytes,
                permanentlyRemovedTargetBytes: 0, removedLocalCopyBytes: 0,
                toolProcessedBytes: 0, volumeObservations: []))
    }
    private func moveToTrash(_ old: OrphanedAppData) throws {
        guard try ManagedCleanupEvidence.identity(old.path) == old.identity,
            try AppLeftoversInspection.nodes(old.path, checker: checker, library: library) == old.nodes,
            rootIsSafe(old.path)
        else { throw DevArtifactSafetyError("Target changed before Trash dispatch.") }
        try trash(old.path)
        var remaining = stat()
        guard lstat(old.path.path, &remaining) != 0, errno == ENOENT else {
            throw DevArtifactSafetyError("Trash did not remove the source target; no success credited.")
        }
    }

}
