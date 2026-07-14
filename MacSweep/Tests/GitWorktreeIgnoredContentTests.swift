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

    private func gitAvailable() async -> Bool {
        await GitArtifactScanner.run(["git", "--version"]).status == 0
    }

    /// Initialize a git repo at `dir` with one committed file and a `.gitignore`.
    @discardableResult
    private func initRepo(at dir: URL) async throws -> Bool {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard await GitArtifactScanner.run(["git", "-C", dir.path, "init"]).status == 0 else { return false }
        // Deterministic identity so commits succeed on hosts without global config.
        _ = await GitArtifactScanner.run(["git", "-C", dir.path, "config", "user.email", "t@example.com"])
        _ = await GitArtifactScanner.run(["git", "-C", dir.path, "config", "user.name", "Test"])
        try "ignored/\n.env\n*.secret\n".write(
            to: dir.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "hello".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = await GitArtifactScanner.run(["git", "-C", dir.path, "add", "-A"])
        return await GitArtifactScanner.run(["git", "-C", dir.path, "commit", "-m", "init"]).status == 0
    }

    @Test func cleanWorktreeWithoutIgnoredContentIsRemovable() async throws {
        guard await gitAvailable() else { return }
        try #require(try await initRepo(at: root))

        // No gitignored content present → safe to remove.
        #expect(await GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == false)
    }

    @Test func gitignoredFileWithContentBlocksRemoval() async throws {
        guard await gitAvailable() else { return }
        try #require(try await initRepo(at: root))

        // A gitignored `.env` with real secrets — invisible to `git status`.
        try "API_KEY=supersecret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        // Sanity: plain porcelain still reports the tree "clean".
        let porcelain = await GitArtifactScanner.run(
            ["git", "-C", root.path, "status", "--porcelain", "--ignore-submodules"]
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(porcelain.isEmpty, "gitignored file must not appear in plain porcelain")

        // Our gate must catch it.
        #expect(await GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true)
    }

    @Test(arguments: [
        "quoted\"name.secret",
        #"back\slash.secret"#,
        "tab\tname.secret",
        "line\nbreak.secret",
        "café.secret"
    ])
    func valuableIgnoredContentWithAdversarialFilenameBlocksRemoval(_ filename: String) async throws {
        guard await gitAvailable() else { return }
        try #require(try await initRepo(at: root))

        try Data("valuable local content".utf8).write(to: root.appendingPathComponent(filename))

        #expect(
            await GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true,
            "Ignored content at filename \(String(reflecting: filename)) must block permanent worktree removal"
        )
    }

    @Test func invalidUTF8StdoutProducesFailureSentinel() async {
        // Invalid UTF-8 path fixtures are not portable across macOS filesystems,
        // so exercise the subprocess boundary directly with one raw 0xFF byte.
        let result = await GitArtifactScanner.run(["sh", "-c", #"printf '\377'"#])

        #expect(result.status != 0, "Invalid UTF-8 stdout must produce a failure sentinel")
        #expect(result.output.isEmpty)
        #expect(result.error.contains("valid UTF-8"), "Decode failure must be explicit")
    }

    @Test func gitignoredDirectoryWithContentBlocksRemoval() async throws {
        guard await gitAvailable() else { return }
        try #require(try await initRepo(at: root))

        let ignoredDir = root.appendingPathComponent("ignored")
        try FileManager.default.createDirectory(at: ignoredDir, withIntermediateDirectories: true)
        try "local db bytes".write(
            to: ignoredDir.appendingPathComponent("dev.sqlite"),
            atomically: true,
            encoding: .utf8
        )

        #expect(await GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true)
    }

    @Test func emptyGitignoredPlaceholderDoesNotBlock() async throws {
        guard await gitAvailable() else { return }
        try #require(try await initRepo(at: root))

        // An empty gitignored file (zero bytes) is not "valuable" — must not block.
        try Data().write(to: root.appendingPathComponent(".env"))

        #expect(await GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == false)
    }

    @Test func nonRepoPathFailsClosed() async throws {
        guard await gitAvailable() else { return }
        // `root` is not a git repo → git errors → we must fail closed (unsafe).
        #expect(await GitArtifactScanner.worktreeHasValuableIgnoredContent(at: root) == true)
    }
}
