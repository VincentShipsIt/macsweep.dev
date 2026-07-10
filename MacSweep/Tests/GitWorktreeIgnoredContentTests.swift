import Foundation
import Testing
@testable import MacSweepCore

/// Regression tests for #79: `git worktree remove` (and `git status --porcelain`)
/// ignore gitignored files, so a worktree whose only extra content is a
/// gitignored `.env` or local DB would be permanently destroyed. The scan- and
/// clean-time gates now refuse such worktrees via
/// `GitArtifactScanner.worktreeHasValuableIgnoredContent(at:)`.
///
/// These tests shell out to real `git`; they no-op cleanly if `git` is absent.
final class GitWorktreeIgnoredContentTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepGitIgnored-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var gitAvailable: Bool {
        GitArtifactScanner.run(["git", "--version"]).status == 0
    }

    /// Initialize a git repo at `dir` with one committed file and a `.gitignore`.
    @discardableResult
    private func initRepo(at dir: URL) throws -> Bool {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard GitArtifactScanner.run(["git", "-C", dir.path, "init"]).status == 0 else { return false }
        // Deterministic identity so commits succeed on hosts without global config.
        _ = GitArtifactScanner.run(["git", "-C", dir.path, "config", "user.email", "t@example.com"])
        _ = GitArtifactScanner.run(["git", "-C", dir.path, "config", "user.name", "Test"])
        try "ignored/\n.env\n*.secret\n".write(
            to: dir.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "hello".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = GitArtifactScanner.run(["git", "-C", dir.path, "add", "-A"])
        return GitArtifactScanner.run(["git", "-C", dir.path, "commit", "-m", "init"]).status == 0
    }

    @Test func cleanWorktreeWithoutIgnoredContentIsRemovable() throws {
        guard gitAvailable else { return }
        try #require(try initRepo(at: root))

        // No gitignored content present → safe to remove.
        #expect(GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == false)
    }

    @Test func gitignoredFileWithContentBlocksRemoval() throws {
        guard gitAvailable else { return }
        try #require(try initRepo(at: root))

        // A gitignored `.env` with real secrets — invisible to `git status`.
        try "API_KEY=supersecret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        // Sanity: plain porcelain still reports the tree "clean".
        let porcelain = GitArtifactScanner.run(
            ["git", "-C", root.path, "status", "--porcelain", "--ignore-submodules"]
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(porcelain.isEmpty, "gitignored file must not appear in plain porcelain")

        // Our gate must catch it.
        #expect(GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true)
    }

    @Test(arguments: [
        "quoted\"name.secret",
        #"back\slash.secret"#,
        "tab\tname.secret",
        "line\nbreak.secret",
        "café.secret"
    ])
    func valuableIgnoredContentWithAdversarialFilenameBlocksRemoval(_ filename: String) throws {
        guard gitAvailable else { return }
        try #require(try initRepo(at: root))

        try Data("valuable local content".utf8).write(to: root.appendingPathComponent(filename))

        #expect(
            GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true,
            "Ignored content at filename \(String(reflecting: filename)) must block permanent worktree removal"
        )
    }

    @Test func gitignoredDirectoryWithContentBlocksRemoval() throws {
        guard gitAvailable else { return }
        try #require(try initRepo(at: root))

        let ignoredDir = root.appendingPathComponent("ignored")
        try FileManager.default.createDirectory(at: ignoredDir, withIntermediateDirectories: true)
        try "local db bytes".write(to: ignoredDir.appendingPathComponent("dev.sqlite"), atomically: true, encoding: .utf8)

        #expect(GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true)
    }

    @Test func emptyGitignoredPlaceholderDoesNotBlock() throws {
        guard gitAvailable else { return }
        try #require(try initRepo(at: root))

        // An empty gitignored file (zero bytes) is not "valuable" — must not block.
        try Data().write(to: root.appendingPathComponent(".env"))

        #expect(GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == false)
    }

    @Test func nonRepoPathFailsClosed() throws {
        guard gitAvailable else { return }
        // `root` is not a git repo → git errors → we must fail closed (unsafe).
        #expect(GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true)
    }
}
