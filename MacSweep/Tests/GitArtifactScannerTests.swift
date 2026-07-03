import Foundation
import Testing
@testable import MacSweepCore

struct GitArtifactScannerTests {
    @Test func parsesWorktreePorcelain() {
        let output = """
        worktree /Users/test/project
        HEAD abc123
        branch refs/heads/main

        worktree /Users/test/.codex/worktrees/old/project
        HEAD def456
        branch refs/heads/feature/old

        worktree /Users/test/.codex/worktrees/detached/project
        HEAD fedcba
        detached

        """

        let entries = GitArtifactScanner.parseWorktreeList(output)

        #expect(entries.count == 3)
        #expect(entries[0].branchName == "main")
        #expect(entries[1].path?.path == "/Users/test/.codex/worktrees/old/project")
        #expect(entries[1].branchName == "feature/old")
        #expect(entries[2].isDetached)
        #expect(entries[2].branchName == nil)
    }

    @Test func parsesBranchRows() {
        let output = """
        feature/old\t2026-05-01T10:30:00+02:00\torigin/feature/old\t[gone]\t
        feature/active\t2026-06-01T10:30:00+02:00\torigin/feature/active\t[ahead 1]\t/Users/test/project
        """

        let rows = GitArtifactScanner.parseBranchRows(output)

        #expect(rows.count == 2)
        #expect(rows[0].name == "feature/old")
        #expect(rows[0].lastCommitDate != nil)
        #expect(rows[0].tracking == "[gone]")
        #expect(rows[0].worktreePath == nil)
        #expect(rows[1].worktreePath == "/Users/test/project")
    }

    @Test func protectsDefaultAndReleaseBranchFamilies() {
        #expect(GitArtifactScanner.isProtectedBranch("main"))
        #expect(GitArtifactScanner.isProtectedBranch("master"))
        #expect(GitArtifactScanner.isProtectedBranch("release/1.2.3"))
        #expect(GitArtifactScanner.isProtectedBranch("hotfix/payment"))
        #expect(!GitArtifactScanner.isProtectedBranch("feature/merged-cleanup"))
    }

    /// Regression for the two-pipe deadlock (issue #85): the runner must drain
    /// stdout and stderr concurrently before `waitUntilExit`. A child that emits
    /// well over the 64 KB pipe buffer on BOTH streams deadlocked the old
    /// read-after-wait ordering (the child blocks on a full pipe, the parent
    /// blocks in wait). If this regresses, the call never returns and the run
    /// trips the time limit instead of hanging the suite forever.
    ///
    /// `CacheAnalyzer.runProcess` carries the byte-identical fix; this covers the
    /// shared idiom via the one runner with `internal` visibility.
    @Test(.timeLimit(.minutes(1)))
    func drainsLargeStdoutAndStderrWithoutDeadlock() {
        // 200 KB to stdout, then 200 KB to stderr — each ~3x the pipe buffer.
        let result = GitArtifactScanner.run([
            "sh", "-c",
            "yes 0123456789 | head -c 200000; yes 9876543210 | head -c 200000 1>&2"
        ])

        #expect(result.status == 0)
        #expect(result.output.count >= 190_000)
        #expect(result.error.count >= 190_000)
    }
}
