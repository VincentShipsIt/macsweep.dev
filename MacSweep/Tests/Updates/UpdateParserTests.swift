import Foundation
import Testing

@testable import MacSweepCore

struct UpdateParserTests {
    @Test func brewFormulaAndCaskVersions() throws {
        let text =
            #"{"formulae":[{"name":"wget","installed_versions":["1.0"],"current_version":"2.0","pinned":false}],"#
            + #""casks":[{"name":"app","installed_versions":["1.0"],"current_version":"2.0"}]}"#
        #expect(try UpdateParsers.brew(text, source: .brewFormula).first?.identifier == "wget")
        #expect(try UpdateParsers.brew(text, source: .brewCask).first?.latest == "2.0")
        let pinned = text.replacingOccurrences(of: "false", with: "true")
        #expect(try UpdateParsers.brew(pinned, source: .brewFormula).first?.retainedReason != nil)
    }

    @Test func npmAndPnpmStructuredFixtures() throws {
        let npm = #"{"@scope/tool":{"current":"1.0.0","latest":"2.0.0","wanted":"1.0.0"}}"#
        let pnpm = #"[{"name":"tool","current":"1.0.0","latest":"2.0.0"}]"#
        #expect(try UpdateParsers.node(npm).first?.identifier == "@scope/tool")
        #expect(try UpdateParsers.node(pnpm).first?.current == "1.0.0")
        #expect(throws: (any Error).self) { try UpdateParsers.node(#"{"error":{"code":"EACCESS"}}"#) }
    }

    @Test func masAndGemTextFixtures() throws {
        let mas = try UpdateParsers.mas("12345 Example App (1.0.0 -> 2.0.0)\n")
        #expect(mas.first?.identifier == "12345")
        #expect(mas.first?.title == "Example App")
        #expect(try UpdateParsers.gem("rake (1.0.0 < 2.0.0)\n").first?.latest == "2.0.0")
        #expect(throws: (any Error).self) { try UpdateParsers.mas("unexpected source warning") }
    }

    @Test func pipxFiltersOnlyPrimaryApplicationAndHonorsPin() throws {
        let list =
            #"{"venvs":{"my-app":{"metadata":{"main_package":{"package":"My_App","package_version":"1.0.0","#
            + #""pinned":true}}}}}"#
        let apps = try UpdateParsers.pipxApps(list)
        let app = try #require(apps.first)
        #expect(app.pinned)
        let outdated =
            #"[{"name":"dependency","version":"1","latest_version":"2"},"#
            + #"{"name":"my-app","version":"1.0.0","latest_version":"2.0.0"}]"#
        #expect(try UpdateParsers.pipxOutdated(outdated, app: app)?.identifier == "my-app")
        #expect(try UpdateParsers.pipxOutdated("[]", app: app) == nil)
    }

    @Test(arguments: ["--all", "foo;touch", "../foo", "file:bad", "x\n--force", "$(id)"])
    func rejectsUnsafePackageNames(_ name: String) {
        for source in UpdateSource.allCases { #expect(!UpdateParsers.validName(name, source: source)) }
    }

    @Test func nativeCommandsHaveExplicitScopeAndNoSudo() {
        let version = UpdateVersion(identifier: "tool", title: "tool", current: "1.0.0", latest: "2.0.0")
        let brew = UpdateCommands.upgrade(version, source: .brewFormula, manager: "/opt/homebrew/bin/brew")
        #expect(brew.arguments.contains("HOMEBREW_NO_SUDO=1"))
        #expect(brew.arguments.contains("HOMEBREW_NO_INSTALL_CLEANUP=1"))
        let npm = UpdateCommands.upgrade(version, source: .npm, manager: "/usr/local/bin/npm")
        #expect(npm.arguments.contains("--ignore-scripts"))
        #expect(npm.arguments.contains("tool@2.0.0"))
        let pipx = UpdateCommands.upgrade(version, source: .pipx, manager: "/usr/local/bin/pipx")
        #expect(pipx.arguments.contains("--pip-args=--no-input --only-binary=:all:"))
    }

    @Test func caskInstallerPrivilegeIsDetected() throws {
        #expect(
            try UpdateProtection.caskRequiresAdministrator(#"{"casks":[{"artifacts":[{"pkg":["Installer.pkg"]}]}]}"#))
        #expect(try !UpdateProtection.caskRequiresAdministrator(#"{"casks":[{"artifacts":[{"app":["App.app"]}]}]}"#))
    }
}
