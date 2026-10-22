import Foundation

enum StaleProjectGit {
    static func inspect(_ root: URL) async -> StaleProjectGitState {
        var state = StaleProjectGitState()
        do {
            let top = try await query(root, ["rev-parse", "--show-toplevel"])
            guard URL(fileURLWithPath: top).resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else {
                throw DevArtifactSafetyError("Repository ownership changed; rescan before acting.")
            }
            let metadata = try await query(root, ["rev-parse", "--absolute-git-dir"])
            let common = try await query(root, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
            state.metadataIsContained = DevArtifactPaths.contains(
                root.resolvingSymlinksInPath(),
                URL(fileURLWithPath: metadata).resolvingSymlinksInPath(),
            )
                && DevArtifactPaths.contains(
                    root.resolvingSymlinksInPath(),
                    URL(fileURLWithPath: common).resolvingSymlinksInPath(),
                )
            state.isClean = try await query(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).isEmpty
            let count = try await query(root, ["rev-list", "--count", "--all", "--not", "--remotes"])
            state.unpushedCommits = Int(count)
            let remotes = try await query(root, ["remote"])
            if let remote = remotes.split(whereSeparator: \.isNewline).first, validRemote(String(remote)) {
                state.remote = try await sanitizedRemote(query(root, ["remote", "get-url", "--", String(remote)]))
            }
            let worktrees = try await query(root, ["worktree", "list", "--porcelain"])
            state.worktreeCount = worktrees.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("worktree ") }
                .count
            if let seconds = await TimeInterval((try? query(root, ["log", "-1", "--format=%ct"])) ?? "") {
                state.lastCommit = Date(timeIntervalSince1970: seconds)
            }
            let checkout = try? await query(
                root, ["reflog", "show", "--date=unix", "--format=%gD", "-1", "--grep-reflog=checkout:", "HEAD"],
            )
            state.lastCheckout = checkout.flatMap(checkoutDate)
        } catch {
            state.issue = "Git inspection is incomplete; checkout removal is unavailable."
        }
        return state
    }

    private static func query(_ root: URL, _ args: [String]) async throws -> String {
        try Task.checkCancellation()
        guard let git = GitArtifactScanner.executablePath(for: "git") else {
            throw DevArtifactSafetyError("Git is unavailable.")
        }
        let result = try await ProcessRunner.runPipeline(stages: [
            ProcessPipelineStage(executable: git, arguments: [
                "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                "-c", "core.untrackedCache=false", "-C", root.path
            ] + args),
            ProcessPipelineStage(executable: "/usr/bin/head", arguments: ["-c", "1048576"])
        ], timeout: 5)
        guard result.didSucceed, result.outputWasValidUTF8, result.output.utf8.count < 1_048_576 else {
            throw DevArtifactSafetyError("Git output exceeded its limit or could not be inspected.")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validRemote(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || [45, 46, 95]
                .contains($0)
        }
    }

    static func sanitizedRemote(_ value: String) -> String {
        if var components = URLComponents(string: value), components.scheme != nil {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string ?? "Remote configured"
        }
        // SCP-style remotes may contain a username but should never display a password/token.
        if let separator = value.lastIndex(of: "@") {
            return String(value[value.index(after: separator)...])
        }
        return value
    }

    static func checkoutDate(_ value: String) -> Date? {
        guard let start = value.range(of: "@{"), let end = value[start.upperBound...].firstIndex(of: "}"),
              let seconds = TimeInterval(value[start.upperBound ..< end]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
