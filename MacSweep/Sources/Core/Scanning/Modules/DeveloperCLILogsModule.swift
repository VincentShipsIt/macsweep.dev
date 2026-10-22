import Darwin
import Foundation

struct DeveloperLogRetention: Equatable, Sendable {
    var minimumAge: TimeInterval = 30 * 86_400
    var retainedBytes: Int64 = 256 * 1_048_576

    var description: String {
        "Keep logs newer than \(Int(minimumAge / 86_400)) days "
            + "and at least \(retainedBytes.formattedFileSize) of newest logs."
    }
}

/// The exact gcloud log layout is the boundary; credentials/configuration siblings are never enumerated.
struct DeveloperCLILogsModule: ScanModule {
    let id = "developer-cli-logs"
    let name = "Developer CLI Logs"
    let description = "Review old gcloud .log files with age and size retention"
    let icon = "doc.text.magnifyingglass"
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var retention = DeveloperLogRetention()
    var now: @Sendable () -> Date = { Date() }
    var processSnapshot: @Sendable () async throws -> DevProcessSnapshot = { try await DevProcessActivity.snapshot() }
    var remove: @Sendable (URL) throws -> Void = {
        try CleanupFileRemover.recoverable($0, module: "developer-cli-logs")
    }

    var root: URL { homeDirectory.appendingPathComponent(".config/gcloud/logs") }

    static func isLogPath(_ path: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let root = home.appendingPathComponent(".config/gcloud/logs").standardizedFileURL
        guard DevArtifactPaths.contains(root, path),
            path.deletingLastPathComponent().deletingLastPathComponent().path == root.path
        else {
            return false
        }
        let day = path.deletingLastPathComponent().lastPathComponent
        let name = path.lastPathComponent
        return day.range(of: #"^\d{4}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil
            && name.range(of: #"^\d{2}\.\d{2}\.\d{2}\.\d+\.log$"#, options: .regularExpression) != nil
    }

    func scan() async throws -> [CleanupItem] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard retention.minimumAge.isFinite, retention.minimumAge >= 86_400, retention.retainedBytes >= 0 else {
            throw DevArtifactSafetyError("Invalid gcloud retention policy.")
        }
        let snapshot = try await processSnapshot()
        let entries: [Entry] = try await DevArtifactIO.run { try self.inventory() }
        var retainedBytes: Int64 = 0
        var items: [CleanupItem] = []
        let cutoff = now().addingTimeInterval(-retention.minimumAge)
        for entry in entries.sorted(by: { $0.date > $1.date }) {
            let keepForSize = retainedBytes < retention.retainedBytes
            let (sum, overflow) = retainedBytes.addingReportingOverflow(entry.size)
            retainedBytes = overflow ? Int64.max : sum
            let blockers = ManagedCleanupEvidence.blockers(snapshot, path: entry.path)
            var reason = ManagedCleanupEvidence.activityReason(snapshot, blockers: blockers)
            do { _ = try await DevArtifactIO.run { try ManagedCleanupEvidence.nodes(entry.path, module: id) } } catch {
                reason = reason ?? error.localizedDescription
            }
            if entry.date >= cutoff {
                reason = "Recent log retained by age policy."
            } else if keepForSize {
                reason = "Newest logs retained by size policy."
            }
            let receipt = ManagedCleanupReceipt(
                identity: entry.identity, nodes: [entry.node], operation: .trash,
                preview: "Owner: gcloud (uid \(getuid())). \(retention.description) Selected old files move to Trash; "
                    + "restore until Trash is emptied. No credentials or configuration files are included.",
                blockers: blockers, retentionReason: reason)
            items.append(
                CleanupItem(
                    id: UUID(), path: entry.path, size: entry.size, type: .file,
                    module: id, moduleName: "gcloud CLI Log", lastModified: entry.date,
                    contentModificationDate: entry.date, cleanupReviewReason: reason, managedCleanupReceipt: receipt))
        }
        return items.sorted { $0.size > $1.size }
    }

    private struct Entry: Sendable {
        let path: URL
        let size: Int64
        let date: Date
        let identity: DevArtifactIdentity
        let node: DevArtifactNode
    }

    private func inventory() throws -> [Entry] {
        _ = try ManagedCleanupEvidence.identity(root)
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR, rootInfo.st_uid == getuid() else {
            throw DevArtifactSafetyError("gcloud log root ownership/type unavailable.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var count = 0
        var entries: [Entry] = []
        for enumeratedDay in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let day = root.appendingPathComponent(enumeratedDay.lastPathComponent)
            count += 1
            guard count < 100_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("gcloud log inventory exceeded its safety limit.")
            }
            guard day.lastPathComponent.range(of: #"^\d{4}\.\d{2}\.\d{2}$"#, options: .regularExpression) != nil else {
                continue
            }
            var directory = stat()
            guard lstat(day.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
                directory.st_uid == getuid()
            else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)
            for enumeratedPath in files {
                let path = day.appendingPathComponent(enumeratedPath.lastPathComponent)
                count += 1
                guard count < 100_000, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw DevArtifactSafetyError("gcloud log inventory exceeded its safety limit.")
                }
                guard Self.isLogPath(path, home: homeDirectory) else { continue }
                var info = stat()
                guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                    info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0,
                    SafetyChecker().validateForCleanup(path, moduleID: id, itemType: .file).isSafe
                else { continue }
                let identity = try ManagedCleanupEvidence.identity(path)
                entries.append(
                    Entry(
                        path: path, size: Int64(info.st_size),
                        date: Date(
                            timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                                + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000),
                        identity: identity, node: DevArtifactNode(path: path.path, status: info)))
            }
        }
        return entries
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        // Recompute retention over the complete exact-root inventory, not just the selection.
        let fresh = try await scan()
        return await cleanItems(items, dryRun: false) { item, _ in
            try Task.checkCancellation()
            guard Self.isLogPath(item.path, home: homeDirectory), let receipt = item.managedCleanupReceipt,
                receipt.isEligible,
                fresh.contains(where: { $0.path == item.path && $0.managedCleanupReceipt?.isEligible == true })
            else { throw DevArtifactSafetyError("Log no longer meets retention/activity policy. Rescan first.") }
            try await DevArtifactIO.run { try ManagedCleanupEvidence.validate(receipt, path: item.path, module: id) }
            let snapshot = try await processSnapshot()
            let blockers = ManagedCleanupEvidence.blockers(snapshot, path: item.path)
            if let reason = ManagedCleanupEvidence.activityReason(snapshot, blockers: blockers) {
                throw DevArtifactSafetyError(reason)
            }
            try await DevArtifactIO.run {
                try ManagedCleanupEvidence.validate(receipt, path: item.path, module: id)
                if !dryRun { try remove(item.path) }
            }
        }
    }
}
