import Darwin
import Foundation
@testable import MacSweepCore
import Testing

final class StaleProjectFixture: @unchecked Sendable {
    let temporary: TempTestDirectory
    let home: URL
    let root: URL

    private let usesBuildFixture: Bool

    init(checkoutTrashFixture: Bool = false) throws {
        temporary = try TempTestDirectory(prefix: "StaleProjects")
        usesBuildFixture = checkoutTrashFixture
        if checkoutTrashFixture {
            home = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: ".build/stale-project-fixtures/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        } else {
            home = temporary.url.resolvingSymlinksInPath()
        }
        root = home.appending(path: "checkout")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        if usesBuildFixture {
            try? FileManager.default.removeItem(at: home)
        }
    }

    @discardableResult func git(_ args: [String]) async throws -> ProcessResult {
        let result = await GitArtifactScanner.run(["git", "-C", root.path] + args)
        try #require(result.didSucceed, Comment(rawValue: result.error))
        return result
    }

    func initialize() async throws {
        try await git(["init", "-q", "-b", "main"])
        for name in ["package.json", "tsconfig.json", "package-lock.json", "capture.json", "conversation.json"] {
            try Data("{}\n".utf8).write(to: root.appending(path: name))
        }
        try Data("node_modules/\nignored-source/\ndist/\n".utf8).write(to: root.appending(path: ".gitignore"))
        try await git(["add", "."])
        try await git([
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-qm",
            "fixture"
        ])
        try await git(["remote", "add", "origin", "https://example.invalid/project.git"])
        try await git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try FileManager.default.createDirectory(
            at: root.appending(path: "ignored-source"),
            withIntermediateDirectories: true,
        )
        try Data("keep ignored source\n".utf8).write(to: root.appending(path: "ignored-source/notes.txt"))
        try FileManager.default.createDirectory(
            at: root.appending(path: "node_modules"),
            withIntermediateDirectories: true,
        )
        try Data(repeating: 1, count: 8192).write(to: root.appending(path: "node_modules/generated.bin"))
    }

    func service() -> StaleProjectsService {
        var service = StaleProjectsService()
        service.home = home
        service.searchPaths = [root]
        service.activity = { DevProcessSnapshot() }
        service.history = StaleProjectHistory(inMemory: true)
        return service
    }

    func project(_ service: StaleProjectsService? = nil) async throws -> StaleProject {
        try #require(try await (service ?? self.service()).inventory().projects.first)
    }

    func job(shared: [URL] = [], issue: String? = nil) -> DevProcessJob {
        DevProcessJob(
            identity: DevProcessIdentity(pid: 424_242, seconds: 1, microseconds: 0, executable: "/fixture/python3"),
            parentPID: 1, directory: home, arguments: ["/fixture/python3", "data-job.py"], openFiles: [],
            sharedDependencies: shared, inspectionIssue: issue,
        )
    }
}

final class StaleProjectMoveLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [URL] = []
    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }; paths.append(url)
    }

    var values: [URL] {
        lock.lock(); defer { lock.unlock() }; return paths
    }
}
