import CryptoKit
import Darwin
import Foundation

/// Includes ignored files, untracked files and Git metadata. Nothing is treated as a cache here.
struct StaleProjectManifest: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let relativePath: String
        let stamp: DevArtifactNode
        let content: String
        let attributes: String

        func matchesCopy(_ other: Entry) -> Bool {
            relativePath == other.relativePath && stamp.mode == other.stamp.mode
                && content == other.content && attributes == other.attributes
        }
    }

    let identity: DevArtifactIdentity
    let entries: [Entry]
    let allocatedBytes: Int64
    let containsNestedGit: Bool

    func matchesCopy(_ other: Self) -> Bool {
        entries.count == other.entries.count && zip(entries, other.entries).allSatisfy { $0.matchesCopy($1) }
    }

    static func capture(
        _ root: URL, policy: StaleProjectPolicy = .init(), checker: SafetyChecker = SafetyChecker(),
        cancellation: StaleProjectCancellation? = nil,
    ) throws -> Self {
        let identity = try ManagedCleanupEvidence.identity(root)
        guard identity.type == S_IFDIR else { throw DevArtifactSafetyError("A real checkout directory is required.") }
        let deadline = ProcessInfo.processInfo.systemUptime + policy.manifestTimeLimit
        var entries: [Entry] = []
        var allocated: Int64 = 0
        func inspect(_ url: URL) throws {
            try Task.checkCancellation()
            try cancellation?.check()
            guard entries.count < policy.maximumManifestEntries, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError(
                    "Full backup inspection exceeded its entry or time limit; source retained.",
                )
            }
            let entry = try entry(url, root: root, deadline: deadline, checker: checker, cancellation: cancellation)
            entries.append(entry.value)
            let (sum, overflow) = allocated.addingReportingOverflow(entry.bytes)
            guard !overflow else { throw DevArtifactSafetyError("Checkout size is unavailable.") }
            allocated = sum
        }
        try inspect(root)
        try enumerate(root, inspect: inspect)
        guard try ManagedCleanupEvidence.identity(root) == identity else {
            throw DevArtifactSafetyError("Checkout identity changed during backup inspection.")
        }
        return Self(
            identity: identity, entries: entries.sorted { $0.relativePath < $1.relativePath },
            allocatedBytes: allocated,
            containsNestedGit: entries.contains { $0.relativePath.hasSuffix("/.git") },
        )
    }

    func validateCurrentMetadata(
        _ root: URL, checker: SafetyChecker, cancellation: StaleProjectCancellation
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var current: [DevArtifactNode] = []
        func inspect(_ url: URL) throws {
            try cancellation.check()
            guard current.count < entries.count, ProcessInfo.processInfo.systemUptime < deadline,
                Self.permitsUserRules(url, checker: checker) else {
                throw DevArtifactSafetyError("Checkout contents or protections changed; source retained.")
            }
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_uid == getuid() else {
                throw DevArtifactSafetyError("Checkout metadata could not be revalidated.")
            }
            current.append(DevArtifactNode(path: url.path, status: status))
        }
        try inspect(root)
        try Self.enumerate(root, inspect: inspect)
        guard try ManagedCleanupEvidence.identity(root) == identity,
            current.sorted(by: { $0.path < $1.path }) == entries.map(\.stamp).sorted(by: { $0.path < $1.path }) else {
            throw DevArtifactSafetyError("Checkout contents changed immediately before Trash; retained.")
        }
    }

    private static func permitsUserRules(_ url: URL, checker: SafetyChecker) -> Bool {
        guard case .none = checker.userRules.decision(for: url.path),
            let physicalParent = realpath(url.deletingLastPathComponent().path, nil) else { return false }
        defer { free(physicalParent) }
        let physical = URL(fileURLWithPath: String(cString: physicalParent)).appending(path: url.lastPathComponent)
        guard case .none = checker.userRules.decision(for: physical.path) else { return false }
        return true
    }

    private static func enumerate(_ root: URL, inspect: (URL) throws -> Void) throws {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [],
            errorHandler: { _, error in failure = error; return false },
        ) else {
            throw DevArtifactSafetyError("Complete checkout contents could not be inspected.")
        }
        guard let physical = realpath(root.path, nil) else {
            throw DevArtifactSafetyError("Checkout path could not be resolved safely.")
        }
        let physicalPath = String(cString: physical)
        free(physical)
        for case let url as URL in enumerator {
            let base = url.path.hasPrefix(physicalPath + "/") ? physicalPath : root.path
            guard url.path.hasPrefix(base + "/") else {
                throw DevArtifactSafetyError("Checkout enumeration escaped its source root.")
            }
            let relative = String(url.path.dropFirst(base.count + 1))
            try inspect(root.appending(path: relative))
        }
        if let failure {
            throw failure
        }
    }

    private static func entry(
        _ url: URL, root: URL, deadline: TimeInterval, checker: SafetyChecker,
        cancellation: StaleProjectCancellation?,
    ) throws -> (value: Entry, bytes: Int64) {
        guard permitsUserRules(url, checker: checker) else {
            throw DevArtifactSafetyError("Protected or ignored checkout content prevents whole-project actions.")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid() else {
            throw DevArtifactSafetyError("Checkout ownership or content metadata is unavailable.")
        }
        let type = info.st_mode & S_IFMT
        guard [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(type),
              !url.lastPathComponent.hasPrefix(".nfs"), !url.lastPathComponent.hasPrefix(".afpDeleted"),
              type != S_IFREG || info.st_nlink == 1
        else {
            throw DevArtifactSafetyError(
                "Special files or hard links require a different backup method; source retained.",
            )
        }
        let stamp = DevArtifactNode(path: url.path, status: info)
        let content: String
        if type == S_IFREG {
            content = try digest(url, deadline: deadline, cancellation: cancellation, expected: stamp)
        } else {
            content = try linkValue(url, type: type)
        }
        let attributes = try StaleProjectMetadata.digest(url, status: info)
        var after = stat()
        guard lstat(url.path, &after) == 0, DevArtifactNode(path: url.path, status: after) == stamp else {
            throw DevArtifactSafetyError("Checkout content changed during backup inspection.")
        }
        let relative = url.path == root.path ? "" : String(url.path.dropFirst(root.path.count + 1))
        return (Entry(relativePath: relative, stamp: stamp, content: content, attributes: attributes),
                Int64(info.st_blocks) * 512)
    }

    static func digest(
        _ url: URL, deadline: TimeInterval, cancellation: StaleProjectCancellation? = nil,
        expected: DevArtifactNode? = nil,
    ) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw DevArtifactSafetyError("A backup file could not be opened safely.") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
            opened.st_uid == getuid(),
            expected == nil || DevArtifactNode(path: url.path, status: opened) == expected else {
            throw DevArtifactSafetyError("Backup file identity changed before hashing.")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try Task.checkCancellation()
            try cancellation?.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Backup hashing exceeded its time limit; source retained.")
            }
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw DevArtifactSafetyError("Backup contents could not be read completely.")
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func linkValue(_ url: URL, type: mode_t) throws -> String {
        guard type == S_IFLNK else { return "" }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = readlink(url.path, &buffer, buffer.count)
        guard count >= 0, count < buffer.count, let text = String(bytes: buffer.prefix(count), encoding: .utf8) else {
            throw DevArtifactSafetyError("Symbolic-link contents are unavailable.")
        }
        return text
    }
}
