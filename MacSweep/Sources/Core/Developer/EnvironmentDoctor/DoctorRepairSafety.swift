import Darwin
import Foundation

extension SafetyChecker {
    /// Explicitly scoped file/link repair. Only the exact direct child of the
    /// doctor's fixed launch/bin inventories is admitted; this is no generic
    /// permission to remove content beneath protected system directories.
    func validateForDoctorRepair(_ finding: DoctorFinding, paths: DoctorPaths) -> ValidationResult {
        guard let path = finding.path, let repair = finding.repair else {
            return .protected(reason: "No exact file repair is available.")
        }
        let parent = path.deletingLastPathComponent()
        guard parent.standardizedFileURL.path == parent.resolvingSymlinksInPath().path,
            !path.pathComponents.contains("..") && !path.pathComponents.contains(".")
        else {
            return .protected(reason: "Repair path or parent changed.")
        }
        if let result = validateUserRules(path.path, mode: .cleanup) { return result }
        let name = path.lastPathComponent.lowercased()
        for pattern in ProtectedPaths.sensitivePatterns {
            let matches = pattern.hasPrefix("*") ? name.hasSuffix(String(pattern.dropFirst())) : name == pattern
            if matches { return .sensitive(pattern: pattern) }
        }
        return validateDoctorFileType(path, repair: repair, paths: paths)
    }

    private func validateDoctorFileType(_ path: URL, repair: DoctorRepair, paths: DoctorPaths) -> ValidationResult {
        let parent = path.deletingLastPathComponent()
        switch repair {
        case .orphanedLaunchItem:
            guard
                paths.launchDirectories.contains(where: {
                    $0.standardizedFileURL.path == parent.standardizedFileURL.path
                }), path.pathExtension == "plist"
            else {
                return .protected(reason: "Not an inventoried launch plist.")
            }
            var status = stat()
            guard lstat(path.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                status.st_nlink == 1, [getuid(), uid_t(0)].contains(status.st_uid)
            else {
                return .protected(reason: "Launch plist ownership or file type is unsupported.")
            }
        case .brokenLink:
            guard
                paths.binDirectories.contains(where: { $0.standardizedFileURL.path == parent.standardizedFileURL.path })
            else {
                return .protected(reason: "Not an inventoried bin link.")
            }
            var status = stat()
            guard lstat(path.path, &status) == 0, status.st_mode & S_IFMT == S_IFLNK,
                [getuid(), uid_t(0)].contains(status.st_uid)
            else {
                return .protected(reason: "Only the selected broken link can be moved.")
            }
        }
        return .safe
    }
}
