import Testing
import Foundation
@testable import MacSweepCLIKit
@testable import MacSweepCore

/// Parser coverage: every command shape the CLI accepts maps to the right
/// `CLICommand`, and every malformed input maps to the right `CLIParseError`.
/// This is the contract agents/scripts depend on, so it's exhaustive by design.
struct CLICommandParserTests {

    // MARK: - scan / dry-run / apply (selection)

    @Test func parsesBareScan() throws {
        #expect(try CLICommandParser.parse(["scan"])
            == .scan(HeadlessSelectionRequest(moduleIDs: nil, smartCare: false), .text))
    }

    @Test func parsesScanWithModulesCSV() throws {
        #expect(try CLICommandParser.parse(["scan", "--modules", "system-cache, trash-bins ,"])
            == .scan(HeadlessSelectionRequest(moduleIDs: ["system-cache", "trash-bins"], smartCare: false), .text))
    }

    @Test func parsesBareDryRun() throws {
        #expect(try CLICommandParser.parse(["dry-run"])
            == .dryRun(HeadlessSelectionRequest(moduleIDs: nil, smartCare: false), .text))
    }

    @Test func parsesSmartCareDryRunAsJson() throws {
        #expect(try CLICommandParser.parse(["dry-run", "--smart-care", "--format", "json"])
            == .dryRun(HeadlessSelectionRequest(moduleIDs: nil, smartCare: true), .json))
    }

    @Test func parsesBareApplyDefaultsNoYes() throws {
        #expect(try CLICommandParser.parse(["apply"])
            == .apply(HeadlessSelectionRequest(moduleIDs: nil, smartCare: false), yes: false, format: .text))
    }

    @Test func parsesApplyWithModulesAndYes() throws {
        #expect(try CLICommandParser.parse(["apply", "--modules", "system-cache,trash-bins", "--yes"])
            == .apply(
                HeadlessSelectionRequest(moduleIDs: ["system-cache", "trash-bins"], smartCare: false),
                yes: true,
                format: .text
            ))
    }

    @Test func parsesApplyYesAndFormatInterleaved() throws {
        #expect(try CLICommandParser.parse(["apply", "--smart-care", "--format", "json", "--yes"])
            == .apply(HeadlessSelectionRequest(moduleIDs: nil, smartCare: true), yes: true, format: .json))
    }

    // MARK: - maintenance

    @Test func parsesMaintenanceAction() throws {
        #expect(try CLICommandParser.parse(["maintenance", "flush-dns"])
            == .maintenance("flush-dns", .text))
    }

    @Test func parsesMaintenanceActionJson() throws {
        #expect(try CLICommandParser.parse(["maintenance", "flush-dns", "--format", "json"])
            == .maintenance("flush-dns", .json))
    }

    @Test func parsesMaintenanceList() throws {
        #expect(try CLICommandParser.parse(["maintenance", "list"])
            == .maintenanceList(.text))
    }

    // MARK: - permissions / modules / version

    @Test func parsesPermissionsStatus() throws {
        #expect(try CLICommandParser.parse(["permissions", "status"])
            == .permissionsStatus(.text))
    }

    @Test func parsesModulesList() throws {
        #expect(try CLICommandParser.parse(["modules", "list", "--format", "json"])
            == .modulesList(.json))
    }

    @Test func parsesVersionAllSpellings() throws {
        #expect(try CLICommandParser.parse(["version"]) == .version(.text))
        #expect(try CLICommandParser.parse(["--version"]) == .version(.text))
        #expect(try CLICommandParser.parse(["-v"]) == .version(.text))
        #expect(try CLICommandParser.parse(["version", "--format", "json"]) == .version(.json))
    }

    // MARK: - space / space lens

    @Test func parsesSpace() throws {
        #expect(try CLICommandParser.parse(["space"]) == .space(.text))
    }

    @Test func parsesSpaceLensDefaults() throws {
        #expect(try CLICommandParser.parse(["space", "lens"])
            == .spaceLens(path: nil, depth: 2, format: .text))
    }

    @Test func parsesSpaceLensPathDepthFormat() throws {
        #expect(try CLICommandParser.parse(["space", "lens", "/tmp", "--depth", "4", "--format", "json"])
            == .spaceLens(path: "/tmp", depth: 4, format: .json))
    }

    // MARK: - login-items

    @Test func parsesLoginItemsList() throws {
        #expect(try CLICommandParser.parse(["login-items", "list"])
            == .loginItemsList(.text))
    }

    @Test func parsesLoginItemEnable() throws {
        #expect(try CLICommandParser.parse(["login-items", "enable", "com.foo.agent"])
            == .loginItemSet(label: "com.foo.agent", enabled: true, yes: false, format: .text))
    }

    @Test func parsesLoginItemDisableWithYes() throws {
        #expect(try CLICommandParser.parse(["login-items", "disable", "com.foo.agent", "--yes"])
            == .loginItemSet(label: "com.foo.agent", enabled: false, yes: true, format: .text))
    }

    @Test func parsesLoginItemRemove() throws {
        #expect(try CLICommandParser.parse(["login-items", "remove", "com.foo.agent", "--format", "json"])
            == .loginItemRemove(label: "com.foo.agent", yes: false, format: .json))
    }

    // MARK: - uninstall

    @Test func parsesUninstallList() throws {
        #expect(try CLICommandParser.parse(["uninstall", "list"])
            == .uninstallList(.text))
    }

    @Test func parsesUninstallAppWithYes() throws {
        #expect(try CLICommandParser.parse(["uninstall", "Slack", "--yes"])
            == .uninstall(app: "Slack", yes: true, format: .text))
    }

    // MARK: - ai

    @Test func parsesAIBare() throws {
        #expect(try CLICommandParser.parse(["ai"]) == .aiAnalysis(deep: false, format: .text))
    }

    @Test func parsesAIScanDeep() throws {
        #expect(try CLICommandParser.parse(["ai", "scan", "--deep"])
            == .aiAnalysis(deep: true, format: .text))
    }

    @Test func parsesAIDeepFlagAlias() throws {
        #expect(try CLICommandParser.parse(["ai", "--ai", "--format", "json"])
            == .aiAnalysis(deep: true, format: .json))
    }

    // MARK: - malware

    @Test func parsesMalwareScan() throws {
        #expect(try CLICommandParser.parse(["malware", "scan"])
            == .malwareScan(useAI: false, format: .text))
    }

    @Test func parsesMalwareScanWithAI() throws {
        #expect(try CLICommandParser.parse(["malware", "scan", "--ai", "--format", "json"])
            == .malwareScan(useAI: true, format: .json))
    }

    // MARK: - homebrew

    @Test func parsesHomebrewOutdatedBothSpellings() throws {
        #expect(try CLICommandParser.parse(["homebrew", "outdated"]) == .homebrewOutdated(.text))
        #expect(try CLICommandParser.parse(["brew", "outdated"]) == .homebrewOutdated(.text))
    }

    @Test func parsesHomebrewUpgradeWithYes() throws {
        #expect(try CLICommandParser.parse(["homebrew", "upgrade", "--yes"])
            == .homebrewUpgrade(yes: true, format: .text))
    }

    // MARK: - shred

    @Test func parsesShredDefaultLevel() throws {
        #expect(try CLICommandParser.parse(["shred", "/tmp/x"])
            == .shred(path: "/tmp/x", level: "standard", yes: false, format: .text))
    }

    @Test func parsesShredExplicitLevelCaseInsensitive() throws {
        #expect(try CLICommandParser.parse(["shred", "/tmp/x", "--level", "PARANOID", "--yes"])
            == .shred(path: "/tmp/x", level: "paranoid", yes: true, format: .text))
    }

    // MARK: - help

    @Test func parsesHelpAllSpellings() throws {
        #expect(try CLICommandParser.parse(["help"]) == .help)
        #expect(try CLICommandParser.parse(["--help"]) == .help)
        #expect(try CLICommandParser.parse(["-h"]) == .help)
    }

    // MARK: - error paths (one per CLIParseError case)

    @Test func missingCommandOnEmptyArgs() {
        #expect(throws: CLIParseError.missingCommand) {
            try CLICommandParser.parse([])
        }
    }

    @Test func unknownCommandRejected() {
        #expect(throws: CLIParseError.unknownCommand("bogus")) {
            try CLICommandParser.parse(["bogus"])
        }
    }

    @Test func missingValueForModules() {
        #expect(throws: CLIParseError.missingValue("--modules")) {
            try CLICommandParser.parse(["scan", "--modules"])
        }
    }

    @Test func missingValueForShredPath() {
        #expect(throws: CLIParseError.missingValue("<path>")) {
            try CLICommandParser.parse(["shred", "--level", "quick"])
        }
    }

    @Test func invalidFormatValue() {
        #expect(throws: CLIParseError.invalidValue(flag: "--format", value: "xml")) {
            try CLICommandParser.parse(["scan", "--format", "xml"])
        }
    }

    @Test func invalidDepthOutOfRange() {
        #expect(throws: CLIParseError.invalidValue(flag: "--depth", value: "9")) {
            try CLICommandParser.parse(["space", "lens", "--depth", "9"])
        }
    }

    @Test func invalidShredLevel() {
        #expect(throws: CLIParseError.invalidValue(flag: "--level", value: "ultra")) {
            try CLICommandParser.parse(["shred", "/tmp/x", "--level", "ultra"])
        }
    }

    @Test func unexpectedArgumentInSelection() {
        #expect(throws: CLIParseError.unexpectedArgument("garbage")) {
            try CLICommandParser.parse(["scan", "garbage"])
        }
    }

    @Test func missingSubcommandVariants() {
        #expect(throws: CLIParseError.missingSubcommand("maintenance")) {
            try CLICommandParser.parse(["maintenance"])
        }
        #expect(throws: CLIParseError.missingSubcommand("permissions")) {
            try CLICommandParser.parse(["permissions"])
        }
        #expect(throws: CLIParseError.missingSubcommand("login-items")) {
            try CLICommandParser.parse(["login-items"])
        }
        #expect(throws: CLIParseError.missingSubcommand("homebrew")) {
            try CLICommandParser.parse(["homebrew"])
        }
        #expect(throws: CLIParseError.missingSubcommand("uninstall")) {
            try CLICommandParser.parse(["uninstall"])
        }
    }

    @Test func unknownLoginItemSubcommandRejected() {
        #expect(throws: CLIParseError.unknownCommand("login-items frobnicate")) {
            try CLICommandParser.parse(["login-items", "frobnicate", "com.foo"])
        }
    }
}

/// Exit-code contract: the mapping from a thrown error to a process exit code is
/// the stable surface agents script against, so it gets its own coverage.
struct CLIExitCodeTests {
    private func code(_ error: Error) -> Int32 { CLIExecutor.exitCode(for: error) }

    @Test func parseErrorsMapToUsage() {
        #expect(code(CLIParseError.missingCommand) == CLIExitCode.usage.rawValue)
        #expect(code(CLIParseError.unknownCommand("x")) == CLIExitCode.usage.rawValue)
        #expect(code(CLIParseError.invalidValue(flag: "--format", value: "xml")) == CLIExitCode.usage.rawValue)
    }

    @Test func executionErrorsMap() {
        #expect(code(CLIExecutionError.confirmationRequired) == CLIExitCode.confirmationRequired.rawValue)
        #expect(code(CLIExecutionError.cleanupCancelled) == CLIExitCode.generic.rawValue)
    }

    @Test func serviceNotFoundErrorsMapToNotFound() {
        #expect(code(HeadlessServiceError.pathNotFound("/x")) == CLIExitCode.notFound.rawValue)
        #expect(code(HeadlessServiceError.homebrewNotInstalled) == CLIExitCode.notFound.rawValue)
        #expect(code(HeadlessServiceError.appNotFound("Slack")) == CLIExitCode.notFound.rawValue)
        #expect(code(HeadlessServiceError.loginItemNotFound("com.foo")) == CLIExitCode.notFound.rawValue)
    }

    @Test func serviceRefusalErrorsMapToRefused() {
        #expect(code(HeadlessServiceError.shredRefused("protected path")) == CLIExitCode.refused.rawValue)
        #expect(code(HeadlessServiceError.appRunning("Slack")) == CLIExitCode.refused.rawValue)
    }

    @Test func serviceUsageErrorsMapToUsage() {
        #expect(code(HeadlessServiceError.conflictingSelection) == CLIExitCode.usage.rawValue)
        #expect(code(HeadlessServiceError.invalidModules(["nope"])) == CLIExitCode.usage.rawValue)
        #expect(code(HeadlessServiceError.unknownMaintenanceAction("nope")) == CLIExitCode.usage.rawValue)
        #expect(code(HeadlessServiceError.ambiguousAppMatch("c", ["a", "b"])) == CLIExitCode.usage.rawValue)
        #expect(code(HeadlessServiceError.loginItemAmbiguous("c", ["a", "b"])) == CLIExitCode.usage.rawValue)
    }

    @Test func serviceOperationalErrorsMapToGeneric() {
        #expect(code(HeadlessServiceError.uninstallFailed("boom")) == CLIExitCode.generic.rawValue)
        #expect(code(HeadlessServiceError.loginItemMutationFailed("boom")) == CLIExitCode.generic.rawValue)
    }

    @Test func unknownErrorFallsBackToGeneric() {
        struct Custom: Error {}
        #expect(code(Custom()) == CLIExitCode.generic.rawValue)
    }
}
