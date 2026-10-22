import Darwin
import Foundation
import Testing

@testable import MacSweepCore

struct DevProcessActivityTests {
    private func job(
        pid: pid_t = 444441, seconds: UInt64 = 1, executable: String = "/tools/swiftc",
        parent: pid_t = 1, arguments: [String]? = nil
    ) -> DevProcessJob {
        DevProcessJob(
            identity: DevProcessIdentity(pid: pid, seconds: seconds, microseconds: 9, executable: executable),
            parentPID: parent, directory: URL(fileURLWithPath: "/projects/app"),
            arguments: arguments ?? [executable, "build"], openFiles: [], sharedDependencies: [],
            inspectionIssue: nil)
    }

    @Test func onlySelectedVerifiedDeveloperJobsAreSignalled() async {
        let compiler = job()
        let unselected = job(pid: 444442)
        let importer = job(pid: 444443, executable: "/tools/python3", arguments: ["python3", "import.py"])
        let ledger = SafetyRemovalLedger()
        let snapshot = DevProcessSnapshot(jobs: [compiler, unselected, importer])
        let errors = await DevProcessActivity.stop(
            selected: [compiler, importer], snapshot: { snapshot },
            signal: { ledger.record(URL(fileURLWithPath: "/\($0.pid)")) })
        #expect(ledger.paths.map(\.lastPathComponent) == ["444441"])
        #expect(errors.count == 1)
        #expect(!importer.isStoppableDeveloperJob)
    }

    @Test func changedCommandAtTheSamePIDIsRetained() async {
        let selected = job()
        let changed = job(arguments: ["/tools/swiftc", "other-project.swift"])
        let errors = await DevProcessActivity.stop(
            selected: [selected],
            snapshot: { DevProcessSnapshot(jobs: [changed]) },
            signal: { _ in Issue.record("A changed command must not be signalled") })
        #expect(errors.count == 1)
    }

    @Test func reusedPIDIsNeverSignalled() async {
        let selected = job()
        let reused = job(seconds: 2)
        let ledger = SafetyRemovalLedger()
        let errors = await DevProcessActivity.stop(
            selected: [selected], snapshot: { DevProcessSnapshot(jobs: [reused]) },
            signal: { ledger.record(URL(fileURLWithPath: "/\($0.pid)")) })
        #expect(errors.count == 1)
        #expect(ledger.paths.isEmpty)
    }

    @Test func unknownDescendantsAndIncompleteInventoryPreventStopping() async {
        let compiler = job()
        let importer = job(
            pid: 444442, executable: "/tools/node", parent: compiler.identity.pid,
            arguments: ["node", "import-data.js"])
        let snapshot = DevProcessSnapshot(jobs: [compiler, importer])
        #expect(!snapshot.canStop(compiler))
        #expect(
            snapshot.blockers(
                target: URL(fileURLWithPath: "/projects/app/dist"),
                project: URL(fileURLWithPath: "/projects/app")
            ).count == 2)
        let ledger = SafetyRemovalLedger()
        let errors = await DevProcessActivity.stop(
            selected: [compiler], snapshot: { snapshot },
            signal: { ledger.record(URL(fileURLWithPath: "/\($0.pid)")) })
        #expect(errors.count == 1)
        #expect(ledger.paths.isEmpty)
        let incomplete = DevProcessSnapshot(jobs: [compiler], issues: ["incomplete"])
        let incompleteErrors = await DevProcessActivity.stop(
            selected: [compiler], snapshot: { incomplete },
            signal: { _ in Issue.record("Must not signal") })
        #expect(incompleteErrors.count == 1)
    }

    @Test(arguments: [
        ("/tools/bun", ["bun", "run", "dev"], true),
        ("/tools/bun", ["bun", "run", "import-data"], false),
        ("/tools/node", ["node", "/project/node_modules/typescript/bin/tsc"], true),
        ("/tools/node", ["node", "/project/import.js"], false),
        ("/System/Tools/swiftc", ["swiftc", "build"], false),
        ("/tools/python3", ["python3", "build"], false)
    ])
    func conservativeStopClassification(_ executable: String, _ arguments: [String], _ expected: Bool) {
        #expect(job(executable: executable, arguments: arguments).isStoppableDeveloperJob == expected)
    }

    @Test func globalBuildCachesAndRunningToolsAreProtectedWithoutAnOpenFile() {
        let compiler = job()
        let derivedData = URL(fileURLWithPath: "/Users/example/Library/Developer/Xcode/DerivedData")
        #expect(DevProcessSnapshot(jobs: [compiler]).blockers(target: derivedData, project: derivedData).count == 1)
        let browser = job(executable: "/caches/ms-playwright/chromium/Chrome")
        let cache = URL(fileURLWithPath: "/caches/ms-playwright")
        #expect(DevProcessSnapshot(jobs: [browser]).blockers(target: cache, project: cache).count == 1)
        let usingArgument = job(executable: "/tools/node", arguments: ["node", "/projects/app/node_modules/tool.js"])
        let dependencies = URL(fileURLWithPath: "/projects/app/node_modules")
        #expect(
            DevProcessSnapshot(jobs: [usingArgument]).blockers(
                target: dependencies,
                project: URL(fileURLWithPath: "/unrelated")
            ).count == 1)
    }

    @Test func nativeInventoryFindsOwnedHelperAndStopChecksItsStartIdentity() async throws {
        let temp = try TempTestDirectory(prefix: "DevProcess")
        try Data("// fixture".utf8).write(to: temp.url.appendingPathComponent("Package.swift"))
        let input = temp.url.appendingPathComponent("generated.bin")
        try Data([1, 2, 3]).write(to: input)
        let inputHandle = try FileHandle(forReadingFrom: input)
        defer { try? inputHandle.close() }
        let helper = temp.url.appendingPathComponent("swiftc")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: helper.path)
        let signed = try await ProcessRunner.run(
            executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", helper.path])
        try #require(signed.didSucceed, Comment(rawValue: signed.error))
        let process = Process()
        process.executableURL = helper
        process.arguments = ["30"]
        process.standardInput = inputHandle
        process.currentDirectoryURL = temp.url
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let identity = try #require(DevProcessActivity.identity(for: process.processIdentifier))
        let snapshot = try await DevProcessActivity.snapshot()
        let owned = try #require(snapshot.jobs.first { $0.identity == identity })
        #expect(owned.directory.standardizedFileURL.path == temp.url.standardizedFileURL.path)
        #expect(owned.name == "swiftc")
        try #require(owned.inspectionIssue == nil, Comment(rawValue: owned.inspectionIssue ?? ""))
        #expect(owned.openFiles.contains { $0.standardizedFileURL.path == input.standardizedFileURL.path })
        let reused = DevProcessJob(
            identity: DevProcessIdentity(
                pid: identity.pid, seconds: identity.seconds + 1,
                microseconds: identity.microseconds, executable: identity.executable),
            parentPID: owned.parentPID, directory: owned.directory, arguments: owned.arguments,
            openFiles: [], sharedDependencies: [], inspectionIssue: nil)
        let rejected = await DevProcessActivity.stop(
            selected: [reused], snapshot: { DevProcessSnapshot(jobs: [reused]) })
        #expect(rejected.count == 1)
        #expect(process.isRunning)
        let errors = await DevProcessActivity.stop(selected: [owned], snapshot: { DevProcessSnapshot(jobs: [owned]) })
        try #require(errors.isEmpty, Comment(rawValue: errors.joined(separator: "; ")))
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }
}
