import Darwin
import Foundation

struct DevArtifactSafetyError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DevArtifactIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let type: mode_t
    let parentDevice: UInt64
    let parentInode: UInt64
    let parentPath: String

    static func read(_ url: URL) throws -> Self {
        var node = stat()
        var parent = stat()
        let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard Darwin.lstat(url.path, &node) == 0, Darwin.lstat(directory.path, &parent) == 0 else {
            throw DevArtifactSafetyError("Target identity could not be inspected.")
        }
        guard node.st_mode & S_IFMT != S_IFLNK, parent.st_mode & S_IFMT == S_IFDIR else {
            throw DevArtifactSafetyError("Symlink targets or changed parent paths are retained.")
        }
        return Self(
            device: UInt64(bitPattern: Int64(node.st_dev)), inode: UInt64(node.st_ino),
            type: node.st_mode & S_IFMT, parentDevice: UInt64(bitPattern: Int64(parent.st_dev)),
            parentInode: UInt64(parent.st_ino), parentPath: directory.path)
    }
}

struct DevArtifactNode: Equatable, Sendable {
    let path: String
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(path: String, status: stat) {
        self.path = path
        device = status.st_dev
        inode = status.st_ino
        mode = status.st_mode
        size = status.st_size
        modifiedSeconds = status.st_mtimespec.tv_sec
        modifiedNanoseconds = status.st_mtimespec.tv_nsec
        changedSeconds = status.st_ctimespec.tv_sec
        changedNanoseconds = status.st_ctimespec.tv_nsec
    }
}

struct DevArtifactGitEvidence: Sendable {
    struct Witness: Equatable, Sendable {
        let path: String
        let node: DevArtifactNode?
    }
    let witnesses: [Witness]
    let repositoryRoot: URL

    static func capture(paths: [URL], repositoryRoot: URL) throws -> Self {
        let witnesses = try Set(paths.map(\.path)).sorted().map { path -> Witness in
            var status = stat()
            if Darwin.fstatat(AT_FDCWD, path, &status, 0) == 0 {
                return Witness(path: path, node: DevArtifactNode(path: path, status: status))
            }
            guard errno == ENOENT || errno == ENOTDIR else {
                throw DevArtifactSafetyError("Git evidence metadata could not be inspected.")
            }
            return Witness(path: path, node: nil)
        }
        return Self(witnesses: witnesses, repositoryRoot: repositoryRoot)
    }

    func validate() throws {
        let current = try Self.capture(
            paths: witnesses.map { URL(fileURLWithPath: $0.path) }, repositoryRoot: repositoryRoot)
        guard current.witnesses == witnesses else {
            throw DevArtifactSafetyError("Git index or ignore evidence changed during inspection. Rescan first.")
        }
    }

    static func paths(root: URL, metadata: URL, target: URL, excludes: URL?) throws -> [URL] {
        var paths = [
            root.appendingPathComponent(".git"), metadata.appendingPathComponent("index"),
            metadata.appendingPathComponent("commondir")
        ]
        let commonFile = metadata.appendingPathComponent("commondir")
        let common: URL
        if FileManager.default.fileExists(atPath: commonFile.path) {
            let relative = try String(contentsOf: commonFile, encoding: .utf8).trimmingCharacters(in: .newlines)
            common =
                URL(fileURLWithPath: relative, relativeTo: URL(fileURLWithPath: metadata.path, isDirectory: true))
                .standardizedFileURL
        } else {
            common = metadata
        }
        paths += [common.appendingPathComponent("config"), common.appendingPathComponent("info/exclude")]
        var parent = target.deletingLastPathComponent()
        while DevArtifactPaths.contains(root, parent) {
            paths.append(parent.appendingPathComponent(".gitignore"))
            if parent.standardizedFileURL.path == root.standardizedFileURL.path { break }
            parent.deleteLastPathComponent()
        }
        if let excludes { paths.append(excludes) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths += [
            home.appendingPathComponent(".gitconfig"), home.appendingPathComponent(".config/git/config"),
            home.appendingPathComponent(".config/git/ignore")
        ]
        return paths
    }
}

struct DevArtifactReceipt: Sendable {
    let identity: DevArtifactIdentity?
    let project: URL
    let reason: String
    let blockers: [DevProcessJob]
    let isEligible: Bool
    var content: [DevArtifactNode] = []
    var projectType: ProjectType?
    var gitEvidence: DevArtifactGitEvidence?
}
