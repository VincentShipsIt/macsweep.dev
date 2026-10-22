import Foundation
import Testing

@testable import MacSweepCore

struct EditorCacheMatchingTests {
    @Test func exactJetBrainsVersionRetainedAndConfigurationNeverRemoved() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let old = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2025.1")
        let current = try fixture.cache("Library/Caches/JetBrains/IntelliJIdea2026.2")
        let configuration = try fixture.cache("Library/Application Support/JetBrains/IntelliJIdea2025.1")
        let unknown = try fixture.cache("Library/Caches/JetBrains/Unrecognized2025.1")
        let report = await fixture.service(apps: .init(jetBrainsSelectors: ["IntelliJIdea2026.2"])).scan()
        #expect(report.findings.first { $0.id == old.path }?.isSelectable == true)
        for path in [current, configuration, unknown] {
            #expect(report.findings.first { $0.id == path.path }?.isSelectable == false)
        }
        try FileManager.default.createDirectory(
            at: old.appending(path: "LocalHistory"), withIntermediateDirectories: true)
        #expect(await fixture.service().scan().findings.first { $0.id == old.path }?.isSelectable == false)
    }

    @Test func everyEditorUsesRecordedLocalDeadWorkspaceAndRetainsRemoteOrExistingPaths() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let live = try fixture.directory("projects/live")
        for editor in EditorCacheProduct.editors {
            _ = try fixture.workspace(
                editor.directory, id: "dead", value: fixture.home.appending(path: "projects/missing").absoluteString)
            _ = try fixture.workspace(editor.directory, id: "live", value: live.absoluteString)
            _ = try fixture.workspace(editor.directory, id: "remote", value: "vscode-remote://ssh-remote/host/project")
            _ = try fixture.workspace(editor.directory, id: "external", value: "file:///Volumes/Offline/project")
        }
        let report = await fixture.service().scan()
        #expect(
            report.findings.filter(\.isSelectable).count == 3,
            Comment(
                rawValue: report.findings.map { $0.candidate.evidence + " / " + ($0.retentionReason ?? "eligible") }
                    .joined(separator: "\n")))
        #expect(report.findings.filter(\.isSelectable).allSatisfy { $0.candidate.path.lastPathComponent == "dead" })
        #expect(report.findings.count == 12)
    }

    @Test func extensionMatcherKeepsNewestStablePrereleaseAndRegisteredVersionsForEveryEditor() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        for editor in EditorCacheProduct.editors {
            for version in ["1.2.0", "1.9.0", "1.10.0", "2.0.0-preview"] {
                _ = try fixture.extensionVersion(version, root: editor.extensionDirectory)
            }
            try fixture.registry(["1.9.0", "1.10.0"], root: editor.extensionDirectory)
        }
        let report = await fixture.service().scan()
        #expect(
            report.findings.filter(\.isSelectable).count == 3,
            Comment(
                rawValue: report.findings.map { $0.candidate.evidence + " / " + ($0.retentionReason ?? "eligible") }
                    .joined(separator: "\n")))
        #expect(
            report.findings.filter(\.isSelectable).allSatisfy {
                $0.candidate.path.lastPathComponent == "fixture.extension-1.2.0"
            })
        try fixture.registry(["1.2.0", "1.9.0", "1.10.0"])
        #expect(
            await fixture.service().scan().findings.filter { $0.candidate.safetyRoot.path.contains(".vscode/") }
                .allSatisfy { !$0.isSelectable })
    }

    @Test func missingRegistryAndUnknownExtensionManifestRetainAllVersions() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        _ = try fixture.extensionVersion("1.0.0")
        _ = try fixture.extensionVersion("2.0.0")
        #expect(await fixture.service().scan().findings.allSatisfy { !$0.isSelectable })
        try fixture.registry(["2.0.0"])
        _ = try fixture.directory(".vscode/extensions/unknown-3.0.0")
        #expect(await fixture.service().scan().findings.allSatisfy { !$0.isSelectable })
    }

    @Test func electronAllowlistRequiresKnownOwnerAndNeverInventoriesSettings() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let owners = Set(EditorCacheProduct.electron.flatMap(\.bundleIDs))
        for app in EditorCacheProduct.electron {
            for cache in ["Cache", "Code Cache", "GPUCache", "Settings", "Local Storage"] {
                _ = try fixture.cache("Library/Application Support/\(app.directory)/\(cache)")
            }
        }
        let report = await fixture.service(apps: .init(installedIDs: owners)).scan()
        #expect(report.findings.count == 12 && report.findings.allSatisfy(\.isSelectable))
        #expect(report.findings.allSatisfy { $0.candidate.evidence.contains("rebuilds") })
        #expect(await fixture.service().scan().findings.allSatisfy { !$0.isSelectable })
        #expect(
            await fixture.service(apps: .init(installedIDs: owners, runningIDs: owners)).scan().findings.allSatisfy {
                !$0.isSelectable
            })
    }

    @Test func installedProductInfoProvidesExactCacheSelector() throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        let app = try fixture.directory("Applications/IDE.app/Contents")
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.jetbrains.intellij"], format: .xml, options: 0)
        try plist.write(to: app.appending(path: "Info.plist"))
        try fixture.json(
            ["dataDirectoryName": "IntelliJIdea2026.2", "version": "2026.2.3"],
            at: app.appending(path: "Resources/product-info.json"))
        var inventory = EditorApplicationInventory()
        try EditorApplicationDiscovery.addApplication(app.deletingLastPathComponent(), to: &inventory)
        #expect(inventory.jetBrainsSelectors == ["IntelliJIdea2026.2"])
        #expect(inventory.installedIDs == ["com.jetbrains.intellij"])
        #expect(
            try EditorApplicationDiscovery.applications(in: [fixture.home.appending(path: "Applications")]).count == 1)
    }
    @Test func multipleInstalledIDEVersionsAndLinkedInstallRootsRetainAllMatchingCaches() async throws {
        let fixture = try EditorCachesFixture()
        defer { fixture.destroy() }
        var inventory = EditorApplicationInventory()
        for selector in ["IntelliJIdea2025.1", "IntelliJIdea2026.2"] {
            let contents = try fixture.directory("Installations/\(selector).app/Contents")
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.jetbrains.intellij"],
                format: .xml, options: 0)
            try plist.write(to: contents.appending(path: "Info.plist"))
            try fixture.json(
                ["dataDirectoryName": selector], at: contents.appending(path: "Resources/product-info.json"))
            _ = try fixture.cache("Library/Caches/JetBrains/" + selector)
        }
        let root = try fixture.directory("Applications")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Linked IDEs"),
            withDestinationURL: fixture.home.appending(path: "Installations"))
        let apps = try EditorApplicationDiscovery.applications(in: [root])
        #expect(apps.count == 2)
        for app in apps { try EditorApplicationDiscovery.addApplication(app, to: &inventory) }
        #expect(inventory.jetBrainsSelectors.count == 2)
        #expect(await fixture.service(apps: inventory).scan().findings.allSatisfy { !$0.isSelectable })
    }

}
