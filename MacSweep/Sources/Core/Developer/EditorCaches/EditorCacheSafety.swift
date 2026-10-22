import Darwin
import Foundation

extension SafetyChecker {
    /// Scoped tree authority for candidates independently proved by EditorCachesService.
    func validateForEditorCacheTreeNode(_ url: URL, within root: URL, homeDirectory: URL) -> ValidationResult {
        let library = homeDirectory.appending(path: "Library").standardizedFileURL
        let extensionRoots = EditorCacheProduct.editors.map {
            homeDirectory.appending(path: $0.extensionDirectory).appending(path: "extensions").standardizedFileURL.path
        }
        if !extensionRoots.contains(root.standardizedFileURL.path) {
            let known =
                ["Caches/JetBrains", "Application Support/JetBrains"]
                + (EditorCacheProduct.editors + EditorCacheProduct.electron).map {
                    "Application Support/" + $0.directory
                }
            guard
                known.contains(where: {
                    library.appending(path: $0).standardizedFileURL.path == root.standardizedFileURL.path
                })
            else {
                return .unknown(reason: "Unknown editor cache owner scope")
            }
            return validateForUninstallLeftoverTreeNode(url, within: root, libraryDirectory: library)
        }
        let path = url.standardizedFileURL
        let boundary = root.standardizedFileURL
        guard path.path == boundary.path || path.path.hasPrefix(boundary.path + "/"),
            path.deletingLastPathComponent().resolvingSymlinksInPath().path == path.deletingLastPathComponent().path,
            boundary.deletingLastPathComponent().resolvingSymlinksInPath().path
                == boundary.deletingLastPathComponent().path
        else {
            return .protected(reason: "Extension content escapes its known root")
        }
        var current = path
        while true {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                return .symlink(reason: "Linked extension content retained")
            }
            if let protection = validateUserRules(current.path, mode: .cleanup) { return protection }
            if ProtectedPaths.sensitivePatterns.contains(where: {
                fnmatch($0.lowercased(), current.lastPathComponent.lowercased(), 0) == 0
            }) {
                return .sensitive(pattern: current.lastPathComponent)
            }
            if current.path == boundary.path { return .safe }
            current.deleteLastPathComponent()
        }
    }
}

enum EditorCacheEvidence {
    static func nodes(_ target: EditorCacheCandidate, home: URL, checker: SafetyChecker) throws -> [DevArtifactNode] {
        _ = try ManagedCleanupEvidence.identity(target.path)
        var nodes: [DevArtifactNode] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        func inspect(_ url: URL) throws {
            guard nodes.count < 50_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Editor cache inspection exceeded its safety limit.")
            }
            if let rule = checker.validateUserRules(url.path, mode: .cleanup), !rule.isSafe {
                throw DevArtifactSafetyError("User-protected editor content retained.")
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
                [mode_t(S_IFREG), mode_t(S_IFDIR)].contains(info.st_mode & S_IFMT),
                info.st_nlink == 1 || info.st_mode & S_IFMT == S_IFDIR,
                checker.validateForEditorCacheTreeNode(url, within: target.safetyRoot, homeDirectory: home).isSafe
            else {
                throw DevArtifactSafetyError("Protected, linked, special or unowned editor content retained.")
            }
            let reserved = ["settings", "settings.json", "keymaps", "options", "localhistory", "backups", ".git"]
            guard !reserved.contains(url.lastPathComponent.lowercased()) else {
                throw DevArtifactSafetyError("Settings, keymaps, Local History and backups are retained.")
            }
            if info.st_mode & S_IFMT == S_IFREG { try inspectLocks(url, status: info) }
            nodes.append(DevArtifactNode(path: url.path, status: info))
        }
        try inspect(target.path)
        guard nodes[0].mode & S_IFMT == S_IFDIR else {
            throw DevArtifactSafetyError("Cache target is not a directory.")
        }
        var failure: Error?
        guard
            let entries = FileManager.default.enumerator(
                at: target.path, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else {
            throw DevArtifactSafetyError("Cache content inventory unavailable.")
        }
        for case let entry as URL in entries { try inspect(entry) }
        if let failure { throw failure }
        return nodes.sorted { $0.path < $1.path }
    }

    private static func inspectLocks(_ url: URL, status: stat) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DevArtifactSafetyError("Cache file could not be opened safely.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_ino == status.st_ino, info.st_dev == status.st_dev,
            flock(descriptor, LOCK_EX | LOCK_NB) == 0
        else {
            throw DevArtifactSafetyError("Locked or changed cache retained.")
        }
        _ = flock(descriptor, LOCK_UN)
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_GETLK, &lock) == 0, lock.l_type == Int16(F_UNLCK) else {
            throw DevArtifactSafetyError("Cache has an active record lock.")
        }
    }
}
