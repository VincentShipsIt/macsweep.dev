import Darwin
import Foundation

/// One bounded traversal for repository and generated-artifact discovery.
/// Explicit roots keep their scope; scanning the home also includes every supported agent worktree home.
enum DeveloperRepositoryDiscovery {
    struct Result: Sendable {
        var roots: [URL] = []
        var issues: [String] = []
    }

    struct Artifact: Sendable {
        let url: URL
        let name: String
        let type: CleanupItem.ItemType
    }

    struct ArtifactResult: Sendable {
        var candidates: [Artifact] = []
        var issues: [String] = []
    }

    static func discover(
        searchPaths: [URL], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        maxDepth: Int = 6, maximumEntries: Int = 500_000, timeLimit: TimeInterval = 15,
        checker: SafetyChecker = SafetyChecker()
    ) throws -> Result {
        let walk = try walk(
            searchPaths: searchPaths, homeDirectory: homeDirectory,
            limits: Limits(depth: maxDepth, entries: maximumEntries, seconds: timeLimit),
            mode: .repositories, checker: checker)
        return Result(roots: walk.repositories, issues: walk.issues)
    }

    static func discoverArtifacts(
        searchPaths: [URL], homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        maxDepth: Int = 6, maximumEntries: Int = 500_000, timeLimit: TimeInterval = 15,
        checker: SafetyChecker = SafetyChecker()
    ) throws -> ArtifactResult {
        let walk = try walk(
            searchPaths: searchPaths, homeDirectory: homeDirectory,
            limits: Limits(depth: maxDepth, entries: maximumEntries, seconds: timeLimit),
            mode: .artifacts, checker: checker)
        return ArtifactResult(candidates: walk.artifacts, issues: walk.issues)
    }

    private enum Mode { case repositories, artifacts }

    private struct Walk {
        var repositories: [URL] = []
        var artifacts: [Artifact] = []
        var issues: [String] = []
        var seen = Set<String>()
        var inspected = 0

        mutating func issue(_ message: String) {
            if !issues.contains(message) { issues.append(message) }
        }
    }

    private struct Limits {
        let depth: Int
        let entries: Int
        let seconds: TimeInterval
    }

    private struct Context {
        let limits: Limits
        let mode: Mode
        let checker: SafetyChecker
        let specialRoots: Set<String>
        let deadline: TimeInterval
    }

    private static func walk(
        searchPaths: [URL], homeDirectory: URL, limits: Limits, mode: Mode, checker: SafetyChecker
    ) throws -> Walk {
        var result = Walk()
        let roots = searchPaths.flatMap { DeveloperScanRoots.paths(in: $0, homeDirectory: homeDirectory) }
        let context = Context(
            limits: limits, mode: mode, checker: checker,
            specialRoots: Set(GitArtifactScanner.worktreeRoots(in: homeDirectory).map(\.path)),
            deadline: ProcessInfo.processInfo.systemUptime + max(0, limits.seconds))
        var seenRoots = Set<String>()
        for root in roots.map(\.standardizedFileURL) where seenRoots.insert(root.path).inserted {
            try Task.checkCancellation()
            result.inspected += 1
            guard result.inspected <= max(0, limits.entries),
                ProcessInfo.processInfo.systemUptime < context.deadline else {
                result.issue("Developer discovery stopped at its safety limit (entry or time); results are partial.")
                return result
            }
            guard ScanFileSystem.exists(atPath: root.path) else { continue }
            guard let identity = try? DevArtifactIdentity.read(root), identity.type == S_IFDIR else {
                result.issue("A developer search root could not be inspected safely; discovery is partial.")
                continue
            }
            if mode == .repositories, isRepository(root) {
                appendRepository(root, result: &result)
                continue
            }
            guard permitsTraversal(root, checker: checker) else {
                result.issue("A protected developer search root was excluded from discovery.")
                continue
            }
            if try !enumerate(root, context: context, result: &result) { return result }
        }
        return result
    }

    private static func enumerate(_ root: URL, context: Context, result: inout Walk) throws -> Bool {
        var unreadable = false
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants], errorHandler: { path, error in
                unreadable = true
                ScanDiagnostics.current?.record(error, at: path)
                return true
            }) else {
            result.issue("A developer search root was unreadable; discovery is partial.")
            return true
        }
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            result.inspected += 1
            guard result.inspected <= max(0, context.limits.entries),
                ProcessInfo.processInfo.systemUptime < context.deadline else {
                result.issue("Developer discovery stopped at its safety limit (entry or time); results are partial.")
                return false
            }
            if enumerator.level > max(0, context.limits.depth) {
                enumerator.skipDescendants()
                result.issue("Developer discovery reached its configured depth; deeper paths were excluded.")
                continue
            }
            if inspect(url, root: root, context: context, result: &result) { enumerator.skipDescendants() }
        }
        if unreadable { result.issue("Developer discovery encountered unreadable paths; results are partial.") }
        return true
    }

    private static func inspect(_ url: URL, root: URL, context: Context, result: inout Walk) -> Bool {
        if context.specialRoots.contains(url.standardizedFileURL.path) { return true }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard let values else {
            result.issue("Developer discovery could not inspect a path; results are partial.")
            return true
        }
        guard values.isSymbolicLink == false else { return true }
        let pattern = context.mode == .artifacts ? DevArtifactPattern.allPatterns.first { $0.matches(url) } : nil
        if shouldSkip(url, pattern: pattern, mode: context.mode,
                      hiddenAllowed: context.specialRoots.contains(root.path)) { return true }
        if context.mode == .repositories, values.isDirectory == true, isRepository(url) {
            appendRepository(url, result: &result)
            return true
        }
        guard permitsTraversal(url, checker: context.checker) else { return true }
        if let pattern {
            if result.seen.insert(url.standardizedFileURL.path).inserted {
                result.artifacts.append(Artifact(
                    url: url, name: pattern.name, type: pattern.fileExtension == nil ? .directory : .file))
            }
            return true
        }
        return false
    }

    private static func appendRepository(_ url: URL, result: inout Walk) {
        if result.seen.insert(url.standardizedFileURL.path).inserted { result.repositories.append(url) }
    }

    private static func isRepository(_ url: URL) -> Bool {
        ScanFileSystem.exists(atPath: url.appending(path: ".git").path)
    }

    private static func permitsTraversal(_ url: URL, checker: SafetyChecker) -> Bool {
        guard case .none = checker.userRules.decision(for: url.path),
            case .none = checker.userRules.decision(for: url.resolvingSymlinksInPath().path) else { return false }
        return true
    }

    private static func shouldSkip(
        _ url: URL, pattern: DevArtifactPattern?, mode: Mode, hiddenAllowed: Bool
    ) -> Bool {
        let name = url.lastPathComponent
        if [".git", ".svn", ".hg", "Library", ".Trash", ".Trashes"].contains(name) { return true }
        if name.hasPrefix("."), pattern == nil, !hiddenAllowed { return true }
        if mode == .artifacts, pattern != nil { return false }
        return ["node_modules", "vendor", "Pods", "target", "build", "dist", ".build", "DerivedData"].contains(name)
    }
}
