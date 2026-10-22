import CryptoKit
import Darwin
import Foundation

extension PrivilegedRunner {
    static func repairDoctorFinding(_ finding: DoctorFinding) async throws {
        let script = try doctorRepairScript(finding, home: FileManager.default.homeDirectoryForCurrentUser)
        let result = try await AuthorizedAdminStream.perform(trustedScript: script, timeout: 120, onOutput: { _, _ in })
        try result.checkedSuccess()
    }

    static func doctorAdministratorRepairIsSupported(_ finding: DoctorFinding) -> Bool {
        guard let path = finding.path, let repair = finding.repair,
            path.lastPathComponent.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil
        else { return false }
        let root = path.deletingLastPathComponent().path
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0 else { return false }
        switch repair {
        case .orphanedLaunchItem:
            return ["/Library/LaunchAgents", "/Library/LaunchDaemons"].contains(root)
                && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_uid == 0 && metadata.st_nlink == 1
        case .brokenLink:
            return ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].contains(root)
                && metadata.st_mode & S_IFMT == S_IFLNK && [getuid(), uid_t(0)].contains(metadata.st_uid)
        }
    }

    static func doctorRepairScript(_ finding: DoctorFinding, home: URL) throws -> String {
        guard finding.requiresAdministrator, doctorAdministratorRepairIsSupported(finding),
            let path = finding.path, let stamp = finding.stamp,
            let repair = finding.repair, !path.pathComponents.contains("..") && !path.pathComponents.contains("."),
            path.deletingLastPathComponent().standardizedFileURL.path
                == path.deletingLastPathComponent().resolvingSymlinksInPath().path,
            path.lastPathComponent.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]*$", options: .regularExpression) != nil
        else {
            throw DevArtifactSafetyError("This system repair requires manual review in Terminal.")
        }
        let launchRoots = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]
        let binRoots = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let root = path.deletingLastPathComponent().path
        let allowed = finding.category == .launchItems ? launchRoots : binRoots
        guard allowed.contains(root), let user = getpwuid(getuid()),
            home.path == URL(fileURLWithPath: String(cString: user.pointee.pw_dir)).resolvingSymlinksInPath().path
        else {
            throw DevArtifactSafetyError("System repair location or user identity is unsupported.")
        }
        var metadata = stat()
        guard lstat(path.path, &metadata) == 0, DevArtifactNode(path: path.path, status: metadata) == stamp else {
            throw DevArtifactSafetyError("System finding changed before authorization.")
        }
        let quote = shellQuote
        let source = quote(path.path)
        let destination = quote(path.lastPathComponent + ".macsweep-" + UUID().uuidString)
        let trash = home.appendingPathComponent(".Trash").path
        let witness = "\(stamp.device):\(stamp.inode):\(stamp.size):\(stamp.modifiedSeconds):\(stamp.changedSeconds)"
        let predicate = try doctorPredicate(repair, path: path, metadata: metadata)
        return """
            [ "$(/usr/bin/id -u)" = 0 ] || exit 125
            [ ! -L \(quote(root)) ] && [ -d \(quote(root)) ] || exit 125
            [ "$(/usr/bin/stat -f '%d:%i:%z:%m:%c' \(source))" = '\(witness)' ] || exit 125
            \(predicate)
            [ -d \(quote(trash)) ] && [ ! -L \(quote(trash)) ] || exit 125
            cd -P \(quote(trash)) || exit 125
            [ "$(/bin/pwd -P)" = \(quote(trash)) ] || exit 125
            [ "$(/usr/bin/stat -f '%u' .)" = '\(getuid())' ] || exit 125
            [ ! -e \(destination) ] && [ ! -L \(destination) ] || exit 125
            /bin/mv -n \(source) \(destination) || exit 125
            [ ! -e \(source) ] && [ ! -L \(source) ] || exit 125
            """
    }
    private static func doctorPredicate(_ repair: DoctorRepair, path: URL, metadata: stat) throws -> String {
        let root = path.deletingLastPathComponent().path
        let launchRoots = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]
        let binRoots = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        let source = shellQuote(path.path)
        let quote = shellQuote
        switch repair {
        case .orphanedLaunchItem(let expected):
            guard launchRoots.contains(root), metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == 0,
                metadata.st_nlink == 1, expected.hasPrefix("/"), !expected.contains("\n")
            else {
                throw DevArtifactSafetyError("System plist ownership is unsupported.")
            }
            let digest = SHA256.hash(data: try AuthorizedFileEvidence.read(path, maximumBytes: 1_048_576)).map {
                String(format: "%02x", $0)
            }.joined()
            return """
                [ -f \(source) ] && [ ! -L \(source) ] || exit 125
                [ "$(/usr/bin/stat -f '%u:%l' \(source))" = '0:1' ] || exit 125
                [ "$(/usr/bin/shasum -a 256 \(source) | /usr/bin/awk '{print $1}')" = '\(digest)' ] || exit 125
                program=$(/usr/libexec/PlistBuddy -c 'Print :Program' \(source) 2>/dev/null) || \\
                  program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' \(source) 2>/dev/null) || exit 125
                [ "$program" = \(quote(expected)) ] && [ ! -e "$program" ] && [ ! -L "$program" ] || exit 125
                """
        case .brokenLink(let target):
            guard binRoots.contains(root), metadata.st_mode & S_IFMT == S_IFLNK else {
                throw DevArtifactSafetyError("Only an exact broken bin link may be repaired.")
            }
            return """
                [ -L \(source) ] && [ ! -e \(source) ] || exit 125
                [ "$(/usr/bin/readlink \(source))" = \(quote(target)) ] || exit 125
                """
        }
    }

}
