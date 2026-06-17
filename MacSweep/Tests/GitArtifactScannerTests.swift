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
}
