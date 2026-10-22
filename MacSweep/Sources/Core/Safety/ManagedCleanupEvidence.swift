import Darwin
import Foundation

/// Evidence belongs to an exact scanned object; an inventory label never authorizes removal.
struct ManagedCleanupReceipt: Sendable {
    let identity: DevArtifactIdentity
    let nodes: [DevArtifactNode]
    let operation: ManagedCleanupOperation
    let preview: String
    let blockers: [DevProcessJob]
    let retentionReason: String?

    var isEligible: Bool { retentionReason == nil }
}

enum ManagedCleanupOperation: Equatable, Sendable {
    case trash
    case bunPrune(executable: String, version: String)
    case uvPrune(executable: String, version: String)

    var isNative: Bool { self != .trash }

    func arguments(path: URL) -> [String] {
        switch self {
        case .trash: return []
        case .bunPrune: return ["pm", "cache", "prune", "--max-age", "30", "--cache-dir", path.path]
        case .uvPrune: return ["cache", "prune", "--cache-dir", path.path, "--no-config", "--offline"]
        }
    }

    var executable: String? {
        switch self {
        case .trash: return nil
        case .bunPrune(let executable, _), .uvPrune(let executable, _): return executable
        }
    }
}

enum ManagedCleanupEvidence {
    static func identity(_ path: URL) throws -> DevArtifactIdentity {
        guard path.isFileURL,
            path.deletingLastPathComponent().resolvingSymlinksInPath().path
                == path.deletingLastPathComponent().standardizedFileURL.path
        else { throw DevArtifactSafetyError("Symbolic-link ancestors are retained.") }
        return try DevArtifactIdentity.read(path)
    }

    /// Bounded, no-follow inventory. Capture ctime as well as mtime to reject replacements and writes.
    static func nodes(_ root: URL, module: String) throws -> [DevArtifactNode] {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var nodes: [DevArtifactNode] = []
        let checker = SafetyChecker()
        func inspect(_ url: URL) throws {
            guard nodes.count < 100_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Content inspection exceeded its safety limit; target retained.")
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid() else {
                throw DevArtifactSafetyError("Ownership or content metadata unavailable; target retained.")
            }
            let type = info.st_mode & S_IFMT
            guard [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(type),
                url.lastPathComponent != ".git",
                checker.validateForCleanup(url, moduleID: module, itemType: type == S_IFREG ? .file : .directory).isSafe
            else { throw DevArtifactSafetyError("Protected or special content retained: \(url.lastPathComponent).") }
            if type == S_IFLNK, !DevArtifactPaths.contains(root, url.resolvingSymlinksInPath()) {
                throw DevArtifactSafetyError("Cache links to external dependencies or environments; target retained.")
            }
            if type == S_IFREG {
                try validateLocks(url, info: info)
            }
            nodes.append(DevArtifactNode(path: url.path, status: info))
        }
        try inspect(root)
        if nodes[0].mode & S_IFMT == S_IFDIR {
            var failure: Error?
            guard
                let entries = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil,
                    errorHandler: { _, error in
                        failure = error
                        return false
                    })
            else { throw DevArtifactSafetyError("Cache contents unavailable.") }
            for case let entry as URL in entries { try inspect(entry) }
            if let failure { throw failure }
        }
        return nodes.sorted { $0.path < $1.path }
    }

    private static func validateLocks(_ url: URL, info: stat) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DevArtifactSafetyError("Cache file could not be opened safely.") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else { throw DevArtifactSafetyError("Cache file is locked or changed; target retained.") }
        _ = flock(descriptor, LOCK_UN)
        var recordLock = flock()
        recordLock.l_type = Int16(F_WRLCK)
        recordLock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &recordLock) == 0, recordLock.l_type == Int16(F_UNLCK) else {
            throw DevArtifactSafetyError("Cache file has an active record lock; target retained.")
        }
    }

    static func blockers(_ snapshot: DevProcessSnapshot, path: URL, manager: String? = nil) -> [DevProcessJob] {
        // A manager may not hold the cache open between operations; retain its cache for the entire job.
        snapshot.jobs.filter { job in
            let managerJob =
                manager.map { manager in
                    job.name == manager || (manager == "uv" && job.name == "uvx")
                        || job.arguments.dropFirst().contains { URL(fileURLWithPath: $0).lastPathComponent == manager }
                        || (manager == "gradle" && job.name == "java"
                            && job.arguments.contains { $0.contains("org.gradle") })
                        || (manager == "mvn" && job.name == "java"
                            && job.arguments.contains { $0.contains("org.codehaus.plexus") || $0.contains("maven") })
                } ?? false
            return managerJob || DevArtifactPaths.contains(path, job.directory)
                || job.openFiles.contains { DevArtifactPaths.overlaps(path, $0) }
                || job.sharedDependencies.contains { DevArtifactPaths.overlaps(path, $0) }
                || DevArtifactPaths.contains(path, URL(fileURLWithPath: job.identity.executable))
                || job.arguments.filter { $0.hasPrefix("/") }.contains {
                    DevArtifactPaths.overlaps(path, URL(fileURLWithPath: $0))
                }
        }
    }

    static func activityReason(_ snapshot: DevProcessSnapshot, blockers: [DevProcessJob]) -> String? {
        if !blockers.isEmpty {
            return "Retained for active jobs / lock holders: " + blockers.map(\.label).joined(separator: ", ")
        }
        let incompleteJobs = snapshot.jobs.contains { !$0.isSystemAgent && $0.inspectionIssue != nil }
        if !snapshot.issues.isEmpty || incompleteJobs {
            return "Activity inspection is incomplete; target retained."
        }
        return nil
    }

    static func validate(_ receipt: ManagedCleanupReceipt, path: URL, module: String) throws {
        guard receipt.isEligible else { throw DevArtifactSafetyError(receipt.retentionReason ?? "Target retained.") }
        guard try identity(path) == receipt.identity, try nodes(path, module: module) == receipt.nodes else {
            throw DevArtifactSafetyError("Content, ownership or identity changed since preview. Rescan first.")
        }
    }
}
