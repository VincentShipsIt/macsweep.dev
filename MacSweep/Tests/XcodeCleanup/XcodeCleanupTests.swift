import Foundation
import Testing

@testable import MacSweepCore

struct XcodeCleanupTests {
    @Test func categoriesAreCompleteAndNoXcodeIsCleanEmptyState() async throws {
        #expect(XcodeCleanupCategory.allCases.count == 6)
        let fixture = try XcodeFixture()
        let inventory = await fixture.service().scan()
        #expect(inventory.targets.isEmpty)
        #expect(!inventory.nativeCommandsAvailable)
        #expect(!inventory.issues.isEmpty)
    }

    @Test func staleSupportAndCachesHaveMeasuredSizesButRecentTargetsStay() async throws {
        let fixture = try XcodeFixture()
        let stale = try fixture.directory("Library/Developer/Xcode/iOS DeviceSupport/1.0")
        let recent = try fixture.directory("Library/Developer/Xcode/watchOS DeviceSupport/2.0", age: 1)
        _ = try fixture.directory("Library/Developer/Xcode/tvOS DeviceSupport/1.0")
        _ = try fixture.directory("Library/Developer/CoreSimulator/Caches/old")
        _ = try fixture.directory("Library/Developer/Xcode/UserData/Previews/old")
        let inventory = await fixture.service().scan()
        #expect(inventory.targets.count == 5)
        #expect(inventory.targets.first { $0.path.path == stale.path }?.canRemove == true)
        #expect(inventory.targets.first { $0.path.path == recent.path }?.canRemove == false)
        #expect(inventory.targets.allSatisfy { ($0.bytes ?? 0) >= 4096 })
    }

    @Test func newestArchivePerApplicationAndUnknownArchivesAreRetained() async throws {
        let fixture = try XcodeFixture()
        let older = try fixture.archive("older", app: "app.a", date: Date(timeIntervalSince1970: 1))
        let newest = try fixture.archive("newest", app: "app.a", date: Date(timeIntervalSince1970: 2))
        let other = try fixture.archive("other", app: "app.b", date: Date(timeIntervalSince1970: 1))
        let unknown = try fixture.archive("unknown", app: nil, date: Date(timeIntervalSince1970: 1))
        let inventory = await fixture.service().scan()
        #expect(inventory.targets.first { $0.path.path == older.path }?.canRemove == true)
        for url in [newest, other, unknown] {
            #expect(inventory.targets.first { $0.path.path == url.path }?.canRemove == false)
        }
    }

    @Test func linkedContentsAndChangedContentsAreRetained() async throws {
        let fixture = try XcodeFixture()
        let root = try fixture.directory("Library/Developer/CoreSimulator/Caches/old")
        let service = fixture.service()
        let original = await service.scan()
        let target = try #require(original.targets.first)
        #expect(target.canRemove)
        try Data("changed".utf8).write(to: root.appendingPathComponent("symbols.bin"))
        let receipt = await service.remove([target], confirmed: true)
        #expect(receipt.removedIDs.isEmpty)
        #expect(!receipt.errors.isEmpty)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"),
            withDestinationURL: fixture.root)
        let linked = await service.scan()
        #expect(linked.targets.first?.canRemove == false)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func protectionRulesAreRefreshedBeforeDispatch() async throws {
        let fixture = try XcodeFixture()
        let root = try fixture.directory("Library/Developer/CoreSimulator/Caches/old")
        let scanned = await fixture.service().scan()
        let target = try #require(scanned.targets.first)
        #expect(target.canRemove)
        let protected = UserProtectionRules(ignoreContents: "", protectContents: root.path, homeURL: fixture.root)
        let service = fixture.service(rules: { protected })
        let receipt = await service.remove([target], confirmed: true)
        #expect(receipt.removedIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func unknownAndLiveActivityRetainEveryTarget() async throws {
        let fixture = try XcodeFixture()
        _ = try fixture.directory("Library/Developer/CoreSimulator/Caches/old")
        let unknown = fixture.service(activity: { DevProcessSnapshot(issues: ["incomplete"]) })
        #expect(await unknown.scan().targets.allSatisfy { !$0.canRemove })
        let job = DevProcessJob(
            identity: DevProcessIdentity(
                pid: 999, seconds: 1, microseconds: 1,
                executable: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            parentPID: 1, directory: URL(fileURLWithPath: "/"), arguments: ["Xcode"],
            openFiles: [], sharedDependencies: [], inspectionIssue: nil)
        let active = fixture.service(activity: { DevProcessSnapshot(jobs: [job]) })
        #expect(await active.scan().targets.allSatisfy { !$0.canRemove })
    }

    @Test func partialReceiptsReportSuccessfulTrashAndKeepFailedTargets() async throws {
        let fixture = try XcodeFixture()
        let first = try fixture.directory("Library/Developer/CoreSimulator/Caches/first")
        let second = try fixture.directory("Library/Developer/CoreSimulator/Caches/second")
        let service = fixture.service(trash: { url in
            if url.path == second.path { throw XcodeCleanupError("fixture failure") }
            try FileManager.default.removeItem(at: url)
        })
        let targets = await service.scan().targets
        let receipt = await service.remove(targets, confirmed: true)
        #expect(receipt.removedIDs.count == 1)
        #expect(receipt.errors.count == 1)
        #expect(receipt.removedBytes == 0)
        #expect(receipt.trashedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func guardAndExplicitConfirmationPreventDispatch() async throws {
        let fixture = try XcodeFixture()
        let root = try fixture.directory("Library/Developer/CoreSimulator/Caches/old")
        let service = fixture.service(guardLimit: 1)
        let targets = await service.scan().targets
        #expect(await service.remove(targets, confirmed: true).removedIDs.isEmpty)
        #expect(await service.remove(targets, confirmed: false).removedIDs.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
    @Test func systemCachesAreInventoriedReadOnlyAndAlwaysRetained() async throws {
        let fixture = try XcodeFixture()
        let root = try fixture.directory("system-caches")
        let files = XcodeCleanupFiles(
            home: fixture.root, applications: [], now: Date(),
            safety: SafetyChecker(userRules: .empty), systemCaches: root)
        let inventory = files.scan(selectedDeveloper: nil)
        let target = try #require(inventory.targets.first)
        #expect(target.bytes == 4096)
        #expect(!target.canRemove)
        #expect(target.evidence == nil)
        #expect(target.retentionReason?.contains("authority") == true)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

}
