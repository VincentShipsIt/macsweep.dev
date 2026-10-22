import Foundation

enum StaleProjectAge: String, Sendable { case stale, recent, unknown }

struct StaleProjectPolicy: Sendable {
    var staleMonths = 6
    var maximumRepositories = 100
    var maximumDiscoveryEntries = 500_000
    var maximumManifestEntries = 100_000
    var manifestTimeLimit: TimeInterval = 30
    var inventoryTimeLimit: TimeInterval = 90
}

struct StaleProjectGitState: Equatable, Sendable {
    var lastCommit: Date?
    var lastCheckout: Date?
    var remote: String?
    var isClean: Bool?
    var unpushedCommits: Int?
    var metadataIsContained = false
    var worktreeCount: Int?
    var issue: String?

    var trashBlocker: String? {
        if let issue {
            return issue
        }
        guard lastCommit != nil else { return "No verified HEAD commit; checkout retained." }
        guard isClean == true else { return "Dirty or unknown Git state; checkout retained." }
        guard remote != nil, unpushedCommits == 0 else {
            return "Local commits are unpushed or remote coverage is unknown; checkout retained."
        }
        guard metadataIsContained, worktreeCount == 1 else {
            return "Linked worktrees or external Git metadata require manual checkout management."
        }
        return nil
    }
}

struct StaleProject: Identifiable, Sendable {
    var id: String {
        path.path
    }

    let path: URL
    let identity: DevArtifactIdentity?
    let totalBytes: Int64?
    let sourceBytes: Int64?
    let artifactBytes: Int64
    let lastFileModification: Date?
    let git: StaleProjectGitState
    let age: StaleProjectAge
    let artifacts: [CleanupItem]
    let archiveBlocker: String?
    let issues: [String]

    var lastActivity: Date? {
        [git.lastCommit, git.lastCheckout, lastFileModification].compactMap(\.self).max()
    }

    var eligibleArtifacts: [CleanupItem] {
        artifacts.filter { $0.devArtifactReceipt?.isEligible == true }
    }
}

struct StaleProjectInventory: Sendable {
    var projects: [StaleProject] = []
    var roots: [URL] = []
    var issues: [String] = []
}

struct StaleArchiveReceipt: Sendable {
    let project: StaleProject
    let destination: URL
    let manifest: StaleProjectManifest
    let archiveIdentity: DevArtifactIdentity
    let archiveStamp: DevArtifactNode
    let archiveDigest: String
    let archiveBytes: Int64
    let trashBlocker: String?
}

typealias StaleProjectCommandRunner = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult
