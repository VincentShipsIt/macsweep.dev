import Foundation
import Testing

@testable import MacSweepCore

struct ToolchainManagerTests {
    @Test(arguments: ToolchainManager.allCases)
    func enumeratesEveryManagerWithExplicitStatus(_ manager: ToolchainManager) async throws {
        let fixture = try ToolchainFixture(manager: manager)
        try fixture.install()
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.count == 1)
        #expect(inventory.installations.first?.manager == manager)
        #expect(inventory.installations.first?.size != nil)
        if manager == .java || manager == .rustup {
            #expect(inventory.installations.first?.status == .unknown)
        } else {
            #expect(inventory.installations.first?.status == .stale)
        }
    }

    @Test func rustupGlobalAndDirectoryOverridesAreActive() async throws {
        let fixture = try ToolchainFixture(manager: .rustup)
        try fixture.install("stable-aarch64-apple-darwin")
        try fixture.install("nightly-aarch64-apple-darwin")
        let settings =
            "default_toolchain = \"stable-aarch64-apple-darwin\"\n[overrides]\n"
            + "\"/example\" = \"nightly-aarch64-apple-darwin\""
        try Data(settings.utf8).write(to: fixture.location.root.appendingPathComponent("settings.toml"))
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.count == 2)
        #expect(inventory.installations.allSatisfy { $0.status == .active && !$0.isSelectable })
    }

    @Test func nvmDefaultMajorAliasProtectsMatchingVersions() async throws {
        let fixture = try ToolchainFixture(manager: .nvm)
        try fixture.install("v18.20.0")
        let alias = fixture.location.root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        try Data("18".utf8).write(to: alias.appendingPathComponent("default"))
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.first?.status == .active)
    }

    @Test func unsupportedMiseSafetyFlagsRetainInstalledVersions() async throws {
        let fixture = try ToolchainFixture(manager: .mise)
        try fixture.install()
        let runner = ToolchainRecordingRunner()
        await runner.configure(help: "uninstall")
        let inventory = try await fixture.service(runner: runner).inventory()
        #expect(inventory.installations.first?.status == .unknown)
        #expect(inventory.installations.first?.command == nil)
    }

    @Test func configuredMiseVersionIsActive() async throws {
        let fixture = try ToolchainFixture(manager: .mise)
        try fixture.install()
        let config = fixture.root.appendingPathComponent(".config/mise")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data("[tools]\npython = \"3.8.0\"".utf8).write(to: config.appendingPathComponent("config.toml"))
        let inventory = try await fixture.service().inventory()
        #expect(inventory.installations.first?.status == .active)
    }

    @Test func dependencyInsideAnotherManagerProtectsRuntime() async throws {
        let fixture = try ToolchainFixture()
        let path = try fixture.install()
        let external = try ToolchainFixture(manager: .rbenv)
        let other = try external.install()
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("python"), withDestinationURL: path)
        var service = fixture.service()
        service.locationsOverride = [fixture.location, external.location]
        let inventory = try await service.inventory()
        #expect(inventory.installations.first(where: { $0.path.path == path.path })?.status == .active)
    }
}
