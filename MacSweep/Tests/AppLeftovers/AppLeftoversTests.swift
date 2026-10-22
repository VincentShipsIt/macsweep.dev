import Darwin
import Foundation
import Testing

@testable import MacSweepCore

struct AppLeftoversTests {
    private struct Fixture {
        let root: URL
        let library: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "app-leftovers-\(UUID())")
                .resolvingSymlinksInPath()
            library = root.appending(path: "Library")
            for category in AppLeftoversInspection.categories {
                try FileManager.default.createDirectory(
                    at: library.appending(path: category), withIntermediateDirectories: true)
            }
        }
        func data(_ category: String, _ name: String, container: Bool = false) throws -> URL {
            let path = library.appending(path: category).appending(path: name)
            if container {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                let metadata = try PropertyListSerialization.data(
                    fromPropertyList: ["MCMMetadataIdentifier": name],
                    format: .xml, options: 0)
                try metadata.write(to: path.appending(path: ".com.apple.containermanagerd.metadata.plist"))
            } else {
                try Data("fixture".utf8).write(to: path)
            }
            try age(path)
            return path
        }
        func age(_ path: URL) throws {
            let old = Date(timeIntervalSinceNow: -60 * 86_400)
            if let entries = FileManager.default.enumerator(at: path, includingPropertiesForKeys: nil) {
                for case let child as URL in entries {
                    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: child.path)
                }
            }
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        }
        func service(_ inventory: AppOwnershipInventory = .init()) -> OrphanedAppDataService {
            var service = OrphanedAppDataService()
            service.library = library
            service.ownership = { inventory }
            service.activity = { DevProcessSnapshot() }
            return service
        }
        func destroy() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func exactContainerMetadataGroundsPreferencesAcrossEveryCategory() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        _ = try fixture.data("Containers", "org.fixture.gone", container: true)
        for category in AppLeftoversInspection.categories where category != "Containers" {
            _ = try fixture.data(category, category == "Preferences" ? "org.fixture.gone.plist" : "org.fixture.gone")
        }
        let report = await fixture.service().scan()
        #expect(report.issues.isEmpty)
        #expect(report.findings.count == 7)
        #expect(report.findings.filter(\.isSelectable).count == 6)
        #expect(report.findings.first { $0.category == "Group Containers" }?.isSelectable == false)
        #expect(report.findings.allSatisfy { !$0.evidence.isEmpty && $0.identifier == "org.fixture.gone" })
    }

    @Test func filenameAloneNeverAuthorizesRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        _ = try fixture.data("Preferences", "org.fixture.guess.plist")
        let finding = try #require(await fixture.service().scan().findings.first)
        #expect(finding.confidence == .uncertain)
        #expect(!finding.isSelectable)
    }

    @Test func installedAndRunningOwnersAreNotReported() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        _ = try fixture.data("Containers", "org.fixture.live", container: true)
        #expect(await fixture.service(.init(installed: ["org.fixture.live"])).scan().findings.isEmpty)
        #expect(await fixture.service(.init(running: ["org.fixture.live"])).scan().findings.isEmpty)
        _ = try fixture.data("Application Support", "Fixture App")
        let report = await fixture.service(.init(installed: ["org.fixture.live"], installedNames: ["fixture app"]))
            .scan()
        #expect(report.findings.isEmpty)
    }

    @Test func siblingVendorAndIncompleteInventoryLockAllMatches() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        _ = try fixture.data("Containers", "org.fixture.gone", container: true)
        #expect(
            await fixture.service(.init(installed: ["org.fixture.sibling"])).scan().findings.allSatisfy {
                !$0.isSelectable
            })
        #expect(
            await fixture.service(.init(issues: ["cask inventory failed"])).scan().findings.allSatisfy {
                !$0.isSelectable
            })
        var service = fixture.service()
        service.activity = { DevProcessSnapshot(issues: ["process inaccessible"]) }
        #expect(await service.scan().findings.allSatisfy { !$0.isSelectable })
    }

    @Test func recentChildAndSymlinkAreRetained() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let path = try fixture.data("Containers", "org.fixture.gone", container: true)
        try Data("recent".utf8).write(to: path.appending(path: "recent"))
        #expect(await fixture.service().scan().findings.allSatisfy { !$0.isSelectable })
        try fixture.age(path)
        try FileManager.default.createSymbolicLink(at: path.appending(path: "link"), withDestinationURL: fixture.root)
        #expect(await fixture.service().scan().findings.allSatisfy { !$0.isSelectable })
    }

    @Test func cleanupUsesFreshOwnerAndIdentityAndSurfacesTrashFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let path = try fixture.data("Containers", "org.fixture.gone", container: true)
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        #expect(finding.isSelectable)
        var dispatched = 0
        service.trash = { _ in dispatched += 1 }
        service.ownership = { .init(installed: ["org.fixture.gone"]) }
        #expect(await service.remove([finding]).itemsProcessed == 0)
        #expect(dispatched == 0)
        service.ownership = { .init() }
        try Data("changed".utf8).write(to: path.appending(path: "changed"))
        #expect(await service.remove([finding]).itemsProcessed == 0)
        #expect(dispatched == 0)
        try fixture.age(path)
        let fresh = try #require(await service.scan().findings.first)
        service.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        let failed = await service.remove([fresh])
        #expect(failed.itemsProcessed == 0 && failed.errors.count == 1)
        service.trash = { path in
            dispatched += 1
            try FileManager.default.removeItem(at: path)
        }
        let success = await service.remove([fresh, fresh])
        #expect(success.itemsProcessed == 1 && success.bytesFreed == 0 && dispatched == 1)
    }

    @Test func hardCapBlocksDispatchFromLiveSize() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        _ = try fixture.data("Containers", "org.fixture.gone", container: true)
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        service.deletionGuard.maxTotalSize = 0
        service.trash = { _ in Issue.record("Hard cap bypassed") }
        #expect(await service.remove([finding]).errors.count == 1)
    }

    @Test func applicationDirectoryInventoryReadsNestedAppBundleIDs() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let bundle = fixture.root.appending(path: "Applications/Utilities/Fixture.app/Contents")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.fixture.live"],
            format: .xml, options: 0)
        try metadata.write(to: bundle.appending(path: "Info.plist"))
        #expect(
            try AppOwnershipDiscovery.bundleIdentifiers(in: fixture.root.appending(path: "Applications")) == [
                "org.fixture.live"
            ])
    }
    @Test func caskFixturesResolveInstalledBundleAndRetainUnknownArtifacts() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let apps = fixture.root.appending(path: "Applications")
        let contents = apps.appending(path: "Fixture.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "org.fixture.live"],
            format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        let known = try AppOwnershipDiscovery.caskOwnership(
            #"{"casks":[{"artifacts":[{"app":["Fixture.app"]}]}]}"#, applicationRoots: [apps])
        #expect(known.installed == ["org.fixture.live"] && known.issues.isEmpty)
        let missing = try AppOwnershipDiscovery.caskOwnership(
            #"{"casks":[{"artifacts":[{"app":["Missing.app"]}]}]}"#, applicationRoots: [apps])
        #expect(!missing.issues.isEmpty)
        #expect(throws: (any Error).self) {
            try AppOwnershipDiscovery.caskOwnership("malformed", applicationRoots: [apps])
        }
    }

    @Test func registeredOwnerOutsideInstallRootsAndReplacedIdentityAreRetained() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let target = try fixture.data("Containers", "org.fixture.gone", container: true)
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        service.registeredOwner = { _ in true }
        #expect(await service.scan().findings.isEmpty)
        service.registeredOwner = { _ in false }
        try FileManager.default.moveItem(at: target, to: fixture.root.appending(path: "previous"))
        _ = try fixture.data("Containers", "org.fixture.gone", container: true)
        service.trash = { _ in Issue.record("Replaced target dispatched") }
        #expect(await service.remove([finding]).itemsProcessed == 0)
    }

    @Test func lockHolderAndFreshProcessBlockerPreventTrash() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let target = try fixture.data("Containers", "org.fixture.gone", container: true)
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        let metadata = target.appending(path: ".com.apple.containermanagerd.metadata.plist")
        let descriptor = open(metadata.path, O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(await service.scan().findings.allSatisfy { !$0.isSelectable })
        _ = flock(descriptor, LOCK_UN)
        service.activity = {
            DevProcessSnapshot(jobs: [
                DevProcessJob(
                    identity: DevProcessIdentity(pid: 1234, seconds: 1, microseconds: 0, executable: "/fixture/app"),
                    parentPID: 1, directory: fixture.root, arguments: ["app"], openFiles: [metadata],
                    sharedDependencies: [], inspectionIssue: nil)
            ])
        }
        service.trash = { _ in Issue.record("Active app data was dispatched") }
        #expect(await service.remove([finding]).itemsProcessed == 0)
    }

    @Test func changedProtectionRulesBlockAnAlreadyPreviewedTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let target = try fixture.data("Containers", "org.fixture.gone", container: true)
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        service.protectionRules = {
            SafetyChecker(
                userRules: UserProtectionRules(
                    ignoreContents: "", protectContents: target.path + "\n",
                    homeURL: fixture.root))
        }
        service.trash = { _ in Issue.record("Fresh protection rules bypassed") }
        #expect(await service.remove([finding]).itemsProcessed == 0)
    }

    @Test func noOpTrashIsAnErrorAndCancelledCallerCannotPublishCompleteInventory() async throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        _ = try fixture.data("Containers", "org.fixture.gone", container: true)
        var service = fixture.service()
        let finding = try #require(await service.scan().findings.first)
        service.trash = { _ in }
        let result = await service.remove([finding])
        #expect(result.itemsProcessed == 0 && result.errors.count == 1)
        #expect(result.accounting?.movedToTrashBytes == 0)
        service.activity = {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return DevProcessSnapshot()
        }
        let task = Task { await service.scan() }
        await Task.yield()
        task.cancel()
        let cancelled = await task.value
        #expect(!cancelled.issues.isEmpty && cancelled.findings.allSatisfy { !$0.isSelectable })
    }

}
