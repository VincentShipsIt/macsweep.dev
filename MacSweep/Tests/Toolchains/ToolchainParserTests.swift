import Foundation
import Testing

@testable import MacSweepCore

struct ToolchainParserTests {
    struct ReferenceFixture: Sendable {
        let filename: String
        let content: String
        let manager: ToolchainManager
        let tool: String
        let version: String
    }

    @Test(arguments: [
        ReferenceFixture(filename: ".nvmrc", content: "lts/*", manager: .nvm, tool: "node", version: "lts/*"),
        ReferenceFixture(
            filename: ".python-version", content: "3.11.4", manager: .pyenv, tool: "python", version: "3.11.4"),
        ReferenceFixture(
            filename: ".ruby-version", content: "ruby-3.3.1", manager: .rbenv, tool: "ruby", version: "3.3.1"),
        ReferenceFixture(
            filename: ".tool-versions", content: "python 3.9.0 3.10.0", manager: .asdf, tool: "python",
            version: "3.10.0"),
        ReferenceFixture(
            filename: "mise.toml", content: "[tools]\nnode = \"20.1.0\"", manager: .mise, tool: "node",
            version: "20.1.0"),
        ReferenceFixture(
            filename: "rust-toolchain.toml", content: "[toolchain]\nchannel = \"nightly\"", manager: .rustup,
            tool: "rust", version: "nightly")
    ])
    func parsesManagerReferences(_ fixture: ReferenceFixture) {
        let result = ToolchainReferenceParser.parse(fixture.content, filename: fixture.filename, source: "fixture")
        #expect(
            result.values.contains {
                $0.manager == fixture.manager && $0.tool == fixture.tool && $0.version == fixture.version
            })
        #expect(result.unknownManagers.isEmpty)
    }

    @Test(arguments: ["--force", "../3.8", "3.8;touch", "node\n--all", "$(whoami)", "a/b", "a b", ""])
    func rejectsUnsafeNativeVersion(_ version: String) {
        #expect(!ToolchainReferenceParser.validVersion(version))
    }

    @Test func retainsDynamicMiseConfiguration() {
        let result = ToolchainReferenceParser.parse(
            "[tools]\nnode = { version = \"20\" }", filename: "mise.toml", source: "fixture")
        #expect(result.unknownManagers.contains(.mise))
    }

    @Test func versionAliasesAndMajorReferencesProtectAllMatches() {
        #expect(ToolchainReferences.matches("18", version: "v18.20.0"))
        #expect(!ToolchainReferences.matches("18", version: "v118.20.0"))
        #expect(ToolchainReferences.matches("stable", version: "stable-aarch64-apple-darwin"))
        #expect(ToolchainReferences.matches("lts/*", version: "v20.1.0"))
        #expect(ToolchainReferences.matches("nightly-2025-01-01", version: "nightly-2025-01-01-aarch64-apple-darwin"))
    }

    @Test func nvmUsesStaticScriptAndPositionalArguments() throws {
        let fixture = try ToolchainFixture(manager: .nvm)
        let command = try #require(
            ToolchainDiscovery.command(location: fixture.location, tool: "node", version: "v18.0.0"))
        #expect(command.executable == "/usr/bin/env")
        #expect(command.arguments.contains("-i"))
        #expect(command.arguments.contains("--noprofile"))
        #expect(command.arguments.contains("--norc"))
        #expect(command.arguments.contains(ToolchainDiscovery.nvmScript))
        #expect(command.arguments.last == "v18.0.0")
        #expect(!ToolchainDiscovery.nvmScript.contains("v18.0.0"))
    }

    @Test func jdkHasNoInventedUninstall() throws {
        let fixture = try ToolchainFixture(manager: .java)
        #expect(ToolchainDiscovery.command(location: fixture.location, tool: "java", version: "jdk-17") == nil)
    }
}
