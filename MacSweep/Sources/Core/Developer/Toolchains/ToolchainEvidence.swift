import Darwin
import Foundation

enum ToolchainEvidence {
    static func inspect(_ root: URL, checker: SafetyChecker) throws -> ToolchainContent {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var nodes: [DevArtifactNode] = []
        var size: Int64 = 0
        var signal = Date.distantPast
        func append(_ path: URL) throws {
            try Task.checkCancellation()
            guard nodes.count < 100_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Runtime inspection exceeded its safety limit.")
            }
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_uid == getuid() else {
                throw DevArtifactSafetyError("Runtime ownership or content metadata unavailable.")
            }
            let type = info.st_mode & S_IFMT
            try validate(path, root: root, type: type, checker: checker)
            if type == S_IFREG {
                let bytes = max(0, Int64(info.st_blocks)).multipliedReportingOverflow(by: 512)
                let total = size.addingReportingOverflow(bytes.partialValue)
                guard !bytes.overflow, !total.overflow else { throw DevArtifactSafetyError("Runtime size overflow.") }
                size = total.partialValue
                signal = max(signal, Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)))
                if info.st_mode & 0o111 != 0 {
                    signal = max(signal, Date(timeIntervalSince1970: Double(info.st_atimespec.tv_sec)))
                }
            }
            nodes.append(.init(path: path.path, status: info))
        }
        try append(root)
        var failure: Error?
        guard
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else {
            throw DevArtifactSafetyError("Runtime contents unavailable.")
        }
        for case let child as URL in entries { try append(child) }
        if let failure { throw failure }
        return ToolchainContent(nodes: nodes.sorted { $0.path < $1.path }, size: size, signal: signal)
    }

    private static func validate(_ path: URL, root: URL, type: mode_t, checker: SafetyChecker) throws {
        guard [mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK)].contains(type) else {
            throw DevArtifactSafetyError("Special runtime content requires manual review.")
        }
        let destination = type == S_IFLNK ? path.resolvingSymlinksInPath() : path
        guard type != S_IFLNK || DevArtifactPaths.contains(root, destination),
            checker.validateForShred(destination).isSafe
        else {
            throw DevArtifactSafetyError("Protected content or an external runtime dependency is retained.")
        }
        if case .sensitive = checker.validateForCleanup(destination) {
            throw DevArtifactSafetyError("Sensitive runtime content requires manual review.")
        }
    }

    static func witness(_ path: URL) throws -> ToolchainWitness {
        var info = stat()
        if lstat(path.path, &info) == 0 {
            return ToolchainWitness(path: path.path, node: .init(path: path.path, status: info))
        }
        guard errno == ENOENT || errno == ENOTDIR else {
            throw DevArtifactSafetyError("Protection metadata unavailable.")
        }
        return ToolchainWitness(path: path.path, node: nil)
    }

    static func validate(_ witnesses: [ToolchainWitness]) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        for expected in witnesses {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline,
                try witness(URL(fileURLWithPath: expected.path)) == expected
            else {
                throw DevArtifactSafetyError("Runtime, references or global-selection evidence changed. Rescan first.")
            }
        }
    }

    static func read(_ path: URL) throws -> String? {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw DevArtifactSafetyError("Version-selection metadata unavailable.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= 65_536 else {
            throw DevArtifactSafetyError("Version-selection file requires manual review.")
        }
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DevArtifactSafetyError("Version-selection file unavailable.") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
            DevArtifactNode(path: path.path, status: opened) == DevArtifactNode(path: path.path, status: info)
        else {
            throw DevArtifactSafetyError("Version-selection file changed during inspection.")
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 65_537) ?? Data()
        var after = stat()
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8),
            lstat(path.path, &after) == 0,
            DevArtifactNode(path: path.path, status: opened) == DevArtifactNode(path: path.path, status: after)
        else {
            throw DevArtifactSafetyError("Version-selection file changed or is unsupported.")
        }
        return text
    }
}
