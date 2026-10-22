import Darwin
import Foundation

enum AppLeftoversInspection {
    static let categories = [
        "Preferences", "Application Support", "Caches", "Containers", "Group Containers",
        "Saved Application State", "Application Scripts"
    ]

    static func guessedIdentifier(_ path: URL) -> String? {
        let name = path.lastPathComponent
        let stripped =
            name.hasSuffix(".plist")
            ? String(name.dropLast(6))
            : name.hasSuffix(".savedState") ? String(name.dropLast(11)) : name
        let parts = stripped.split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty } ? stripped : nil
    }

    /// Only an ordinary container's own Container Manager record establishes ownership.
    /// Group-container IDs identify shared data, not every entitled application.
    static func containerOwner(_ path: URL) -> String? {
        guard path.deletingLastPathComponent().lastPathComponent == "Containers",
            (try? ManagedCleanupEvidence.identity(path)) != nil
        else { return nil }
        let metadata = path.appending(path: ".com.apple.containermanagerd.metadata.plist")
        guard let attributes = try? metadata.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
            attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) < 1_048_576,
            let data = try? Data(contentsOf: metadata),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = info["MCMMetadataIdentifier"] as? String,
            identifier == path.lastPathComponent, guessedIdentifier(path) == identifier,
            !identifier.hasPrefix("group.")
        else { return nil }
        return identifier
    }

    static func nodes(_ root: URL, checker: SafetyChecker, library: URL) throws -> [DevArtifactNode] {
        _ = try ManagedCleanupEvidence.identity(root)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var nodes: [DevArtifactNode] = []
        func inspect(_ path: URL) throws {
            guard nodes.count < 50_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Content inspection exceeded its limit.")
            }
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_uid == getuid(),
                [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(info.st_mode & S_IFMT),
                info.st_nlink == 1 || info.st_mode & S_IFMT == S_IFDIR
            else {
                throw DevArtifactSafetyError("Unowned, linked or special content retained.")
            }
            guard checker.validateForUninstallLeftoverTreeNode(path, within: root, libraryDirectory: library).isSafe
            else {
                throw DevArtifactSafetyError("Protected or sensitive app data retained.")
            }
            if info.st_mode & S_IFMT == S_IFREG { try validateLocks(path, info: info) }
            nodes.append(DevArtifactNode(path: path.path, status: info))
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
            else {
                throw DevArtifactSafetyError("Content inventory unavailable.")
            }
            for case let entry as URL in entries { try inspect(entry) }
            if let failure { throw failure }
        }
        return nodes.sorted { $0.path < $1.path }
    }
    private static func validateLocks(_ path: URL, info: stat) throws {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DevArtifactSafetyError("App data could not be opened safely.") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            throw DevArtifactSafetyError("App data is locked or changed; target retained.")
        }
        _ = flock(descriptor, LOCK_UN)
        var recordLock = flock()
        recordLock.l_type = Int16(F_WRLCK)
        recordLock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &recordLock) == 0, recordLock.l_type == Int16(F_UNLCK) else {
            throw DevArtifactSafetyError("App data has an active record lock; target retained.")
        }
    }

}
