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
            == .spaceLens(path: nil, depth: 2, minSize: 0, format: .text))
    }

    @Test func parsesSpaceLensPathDepthFormat() throws {
        #expect(try CLICommandParser.parse(["space", "lens", "/tmp", "--depth", "4", "--format", "json"])
            == .spaceLens(path: "/tmp", depth: 4, minSize: 0, format: .json))
    }

    @Test func parsesSpaceLensMinSizeSuffixes() throws {
        #expect(try CLICommandParser.parse(["space", "lens", "--min-size", "100MB"])
            == .spaceLens(path: nil, depth: 2, minSize: 100 * 1024 * 1024, format: .text))
        #expect(try CLICommandParser.parse(["space", "lens", "/tmp", "--min-size", "2G", "--format", "json"])
            == .spaceLens(path: "/tmp", depth: 2, minSize: 2 * 1024 * 1024 * 1024, format: .json))
    }

    @Test func parsesSpaceLensMinSizeBareBytes() throws {
        #expect(try CLICommandParser.parse(["space", "lens", "--min-size", "4096"])
            == .spaceLens(path: nil, depth: 2, minSize: 4096, format: .text))
    }

    @Test func invalidMinSizeRejected() {
        #expect(throws: CLIParseError.invalidValue(flag: "--min-size", value: "huge")) {
            try CLICommandParser.parse(["space", "lens", "--min-size", "huge"])
        }
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

    @Test func parsesHomebrewCleanup() throws {
        #expect(try CLICommandParser.parse(["homebrew", "cleanup"])
            == .homebrewCleanup(yes: false, format: .text))
        #expect(try CLICommandParser.parse(["brew", "cleanup", "--yes", "--format", "json"])
            == .homebrewCleanup(yes: true, format: .json))
    }

    @Test func parsesHomebrewLeaves() throws {
        #expect(try CLICommandParser.parse(["homebrew", "leaves"]) == .homebrewLeaves(.text))
        #expect(try CLICommandParser.parse(["brew", "leaves", "--format", "json"]) == .homebrewLeaves(.json))
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

    // MARK: - network wifi

    @Test func parsesWiFiList() throws {
        #expect(try CLICommandParser.parse(["network", "wifi", "list"]) == .wifiList(.text))
        #expect(try CLICommandParser.parse(["network", "wifi", "list", "--format", "json"]) == .wifiList(.json))
    }

    @Test func parsesWiFiRemoveExplicitFlag() throws {
        #expect(try CLICommandParser.parse(["network", "wifi", "remove", "--ssid", "HomeWiFi", "--yes"])
            == .wifiRemove(ssid: "HomeWiFi", yes: true, format: .text))
    }

    @Test func parsesWiFiRemovePositionalSSID() throws {
        #expect(try CLICommandParser.parse(["network", "wifi", "remove", "HomeWiFi"])
            == .wifiRemove(ssid: "HomeWiFi", yes: false, format: .text))
    }

    @Test func wifiRemoveMissingSSIDRejected() {
        #expect(throws: CLIParseError.missingValue("--ssid")) {
            try CLICommandParser.parse(["network", "wifi", "remove"])
        }
    }

    // MARK: - network ssh

    @Test func parsesSSHList() throws {
        #expect(try CLICommandParser.parse(["network", "ssh", "list", "--format", "json"]) == .sshList(.json))
    }

    @Test func parsesSSHRemoveHost() throws {
        #expect(try CLICommandParser.parse(["network", "ssh", "remove", "--host", "github.com"])
            == .sshRemove(host: "github.com", all: false, yes: false, format: .text))
    }

    @Test func parsesSSHRemoveAll() throws {
        #expect(try CLICommandParser.parse(["network", "ssh", "remove", "--all", "--yes"])
            == .sshRemove(host: nil, all: true, yes: true, format: .text))
    }

    @Test func sshRemoveConflictingSelectionRejected() {
        #expect(throws: CLIParseError.unexpectedArgument("--all")) {
            try CLICommandParser.parse(["network", "ssh", "remove", "--host", "x", "--all"])
        }
    }

    @Test func sshRemoveEmptySelectionRejected() {
        #expect(throws: CLIParseError.missingValue("--host or --all")) {
            try CLICommandParser.parse(["network", "ssh", "remove"])
        }
    }

    @Test func networkMissingSubcommandRejected() {
        #expect(throws: CLIParseError.missingSubcommand("network")) {
            try CLICommandParser.parse(["network"])
        }
    }

    // MARK: - processes

    @Test func parsesProcessesListDefaultSort() throws {
        #expect(try CLICommandParser.parse(["processes", "list"])
            == .processesList(sort: "memory", format: .text))
    }

    @Test func parsesProcessesListSortCaseInsensitive() throws {
        #expect(try CLICommandParser.parse(["processes", "list", "--sort", "CPU"])
            == .processesList(sort: "cpu", format: .text))
    }

    @Test func processesListInvalidSortRejected() {
        #expect(throws: CLIParseError.invalidValue(flag: "--sort", value: "disk")) {
            try CLICommandParser.parse(["processes", "list", "--sort", "disk"])
        }
    }

    @Test func parsesProcessesQuit() throws {
        #expect(try CLICommandParser.parse(["processes", "quit", "1234", "--force", "--yes"])
            == .processesQuit(target: "1234", force: true, yes: true, format: .text))
    }

    @Test func processesQuitMissingTargetRejected() {
        #expect(throws: CLIParseError.missingValue("processes quit <pid|name>")) {
            try CLICommandParser.parse(["processes", "quit"])
        }
    }

    // MARK: - privacy

    @Test func parsesPrivacyActions() throws {
        #expect(try CLICommandParser.parse(["privacy", "clear-clipboard"])
            == .privacyClear(action: "clear-clipboard", yes: false, format: .text))
        #expect(try CLICommandParser.parse(["privacy", "clear-terminal-history", "--yes"])
            == .privacyClear(action: "clear-terminal-history", yes: true, format: .text))
        #expect(try CLICommandParser.parse(["privacy", "clear-recent-docs", "--format", "json"])
            == .privacyClear(action: "clear-recent-docs", yes: false, format: .json))
    }

    @Test func privacyUnknownActionRejected() {
        #expect(throws: CLIParseError.unknownCommand("privacy clear-everything")) {
            try CLICommandParser.parse(["privacy", "clear-everything"])
        }
    }

    // MARK: - monitor

    @Test func parsesMonitor() throws {
        #expect(try CLICommandParser.parse(["monitor"]) == .monitor(.text))
        #expect(try CLICommandParser.parse(["monitor", "--format", "json"]) == .monitor(.json))
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
        #expect(code(HeadlessServiceError.networkOperationFailed("boom")) == CLIExitCode.generic.rawValue)
    }

    @Test func parityNotFoundErrorsMapToNotFound() {
        #expect(code(HeadlessServiceError.wifiNetworkNotFound("Home")) == CLIExitCode.notFound.rawValue)
        #expect(code(HeadlessServiceError.sshHostNotFound("github.com")) == CLIExitCode.notFound.rawValue)
        #expect(code(HeadlessServiceError.processNotFound("Slack")) == CLIExitCode.notFound.rawValue)
    }

    @Test func parityRefusalErrorsMapToRefused() {
        #expect(code(HeadlessServiceError.processQuitRefused("launchd (pid 1)")) == CLIExitCode.refused.rawValue)
    }

    @Test func parityUsageErrorsMapToUsage() {
        #expect(code(HeadlessServiceError.processAmbiguous("node", ["100", "200"])) == CLIExitCode.usage.rawValue)
        #expect(code(HeadlessServiceError.unknownPrivacyAction("nope")) == CLIExitCode.usage.rawValue)
    }

    @Test func unknownErrorFallsBackToGeneric() {
        struct Custom: Error {}
        #expect(code(Custom()) == CLIExitCode.generic.rawValue)
    }
}
