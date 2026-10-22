import Darwin
import Foundation

enum DoctorFileChecks {
    static func scan(_ paths: DoctorPaths, checker: SafetyChecker) throws -> DoctorInventory {
        var inventory = DoctorInventory()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var count = 0
        for root in paths.launchDirectories + paths.binDirectories {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                inventory.issues.append("File-check budget reached; inventory is partial.")
                break
            }
            do {
                let children = try children(root)
                for child in children {
                    try Task.checkCancellation()
                    count += 1
                    guard count <= 20_000, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw DevArtifactSafetyError("File-check budget reached; inventory is partial.")
                    }
                    let finding: DoctorFinding?
                    if paths.launchDirectories.contains(where: { $0.path == root.path }) {
                        finding = try launchItem(child, home: paths.home)
                    } else {
                        finding = try brokenLink(child)
                    }
                    if var finding {
                        let validation = checker.validateForDoctorRepair(finding, paths: paths)
                        if !validation.isSafe { finding.retentionReason = validation.reason ?? "Repair retained." }
                        inventory.findings.append(finding)
                    }
                }
            } catch is CancellationError { throw CancellationError() } catch {
                inventory.issues.append("\(root.path): \(error.localizedDescription)")
            }
        }
        return inventory
    }

    private static func children(_ root: URL) throws -> [URL] {
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0 else {
            if errno == ENOENT { return [] }
            throw DevArtifactSafetyError("Check root is unreadable.")
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
            root.standardizedFileURL.path == root.resolvingSymlinksInPath().path
        else {
            throw DevArtifactSafetyError("Linked or unexpected check root retained.")
        }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }

    static func launchItem(_ path: URL, home: URL) throws -> DoctorFinding? {
        guard path.pathExtension == "plist" else { return nil }
        var status = stat()
        guard lstat(path.path, &status) == 0 else { throw DevArtifactSafetyError("Plist metadata unavailable.") }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size <= 1_048_576 else { return nil }
        let data = try AuthorizedFileEvidence.read(
            path, maximumBytes: 1_048_576,
            expected: DevArtifactNode(path: path.path, status: status))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw DevArtifactSafetyError("Launch plist is unreadable.")
        }
        guard let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
            program.hasPrefix("/"), !program.contains("\n")
        else { return nil }
        guard try missing(program) else { return nil }
        var after = stat()
        guard lstat(path.path, &after) == 0,
            DevArtifactNode(path: path.path, status: status) == DevArtifactNode(path: path.path, status: after)
        else { throw DevArtifactSafetyError("Launch item changed during inspection.") }
        let system = !DevArtifactPaths.contains(home, path)
        return DoctorFinding(
            category: .launchItems, path: path,
            evidence: "The configured executable is missing: \(program)",
            remediation: "Restore the missing tool, or move this orphaned launch plist to Trash. "
                + "An already loaded launch job is not stopped by this repair.",
            requiresAdministrator: system, repair: .orphanedLaunchItem(program: program),
            stamp: DevArtifactNode(path: path.path, status: status))
    }

    static func brokenLink(_ path: URL) throws -> DoctorFinding? {
        var status = stat()
        guard lstat(path.path, &status) == 0 else { throw DevArtifactSafetyError("Link metadata unavailable.") }
        guard status.st_mode & S_IFMT == S_IFLNK else { return nil }
        let raw = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
        let target =
            raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : path.deletingLastPathComponent().appendingPathComponent(raw).standardizedFileURL
        guard try missing(target.path) else { return nil }
        return DoctorFinding(
            category: .links, path: path,
            evidence: "Broken link → \(raw)",
            remediation: "Move the broken link itself to Trash, or reinstall its owner.",
            requiresAdministrator: access(path.deletingLastPathComponent().path, W_OK) != 0,
            repair: .brokenLink(destination: raw), stamp: DevArtifactNode(path: path.path, status: status))
    }

    static func missing(_ path: String) throws -> Bool {
        var status = stat()
        if fstatat(AT_FDCWD, path, &status, 0) == 0 { return false }
        guard errno == ENOENT || errno == ENOTDIR else {
            throw DevArtifactSafetyError("Target existence is unknown; permission or link-loop failure retained.")
        }
        return true
    }
}
