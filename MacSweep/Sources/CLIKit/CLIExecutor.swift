import Foundation
import Darwin
import MacSweepCore

struct CLICommandMetadata: Codable {
    let command: String
    let timestamp: Date
    let executedModules: [String]
}

struct CLIScanOutput: Codable {
    let metadata: CLICommandMetadata
    let permissions: HeadlessPermissionStatusReport
    let findings: [HeadlessFinding]
    let summary: HeadlessSummary
    let cleanup: HeadlessCleanupResult?
}

struct CLIModulesOutput: Codable {
    let metadata: CLICommandMetadata
    let modules: [HeadlessModuleDescriptor]
}

struct CLIPermissionsOutput: Codable {
    let metadata: CLICommandMetadata
    let permissions: HeadlessPermissionStatusReport
}

struct CLIMaintenanceOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessMaintenanceRunResult
}

struct CLIMaintenanceListOutput: Codable {
    let metadata: CLICommandMetadata
    let actions: [HeadlessMaintenanceActionDescriptor]
}

struct CLIVersionOutput: Codable {
    let metadata: CLICommandMetadata
    let version: String
}

struct CLISpaceOutput: Codable {
    let metadata: CLICommandMetadata
    let disk: HeadlessDiskUsage
}

struct CLILoginItemsOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessLoginItemsReport
}

struct CLILoginItemMutationOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessLoginItemMutationResult
}

struct CLISpaceLensOutput: Codable {
    let metadata: CLICommandMetadata
    let tree: HeadlessDiskTree
}

struct CLIUninstallListOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessUninstallableAppsReport
}

struct CLIUninstallOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessUninstallResult
}

struct CLIAIOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessCacheReport
}

struct CLIMalwareOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessMalwareScanReport
}

struct CLIHomebrewOutput: Codable {
    let metadata: CLICommandMetadata
    let report: HeadlessHomebrewReport
}

struct CLIHomebrewUpgradeOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessHomebrewUpgradeResult
}

struct CLIShredOutput: Codable {
    let metadata: CLICommandMetadata
    let result: HeadlessShredResult
}

enum CLIExecutionError: Error, LocalizedError {
    case confirmationRequired
    case cleanupCancelled

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Refusing destructive operation without --yes in non-interactive mode."
        case .cleanupCancelled:
            return "Operation cancelled."
        }
    }
}

/// Semantic process exit codes for agent/script consumers. Stable contract:
/// a nonzero code distinguishes usage errors, missing targets, refusals, and
/// confirmation gates from generic failures.
public enum CLIExitCode: Int32 {
    case success = 0
    case generic = 1
    case usage = 2
    case confirmationRequired = 3
    case notFound = 4
    case refused = 5
}

public enum CLIExecutor {
    @discardableResult
    public static func run(command: CLICommand) async throws -> Int32 {
        let service = MacSweepHeadlessService()

        switch command {
        case .help:
            print(CLIHelp.text)
            return CLIExitCode.success.rawValue

        case .scan(let request, let format):
            let result = try await service.scan(request: request)
            try emitScanOutput(
                command: "scan",
                scan: result,
                cleanup: nil,
                format: format
            )
            return CLIExitCode.success.rawValue

        case .dryRun(let request, let format):
            let plan = try await service.prepareCleanup(request: request)
            try emitScanOutput(
                command: "dry-run",
                scan: plan.scan,
                cleanup: plan.cleanupPreview,
                format: format
            )
            return CLIExitCode.success.rawValue

        case .apply(let request, let yes, let format):
            let plan = try await service.prepareCleanup(request: request)
            if !yes {
                try confirmCleanup(plan.cleanupPreview)
            }
            let result = try await service.executeCleanup(plan)
            try emitScanOutput(
                command: "apply",
                scan: result.scan,
                cleanup: result.cleanup,
                format: format
            )
            return CLIExitCode.success.rawValue

        case .maintenance(let actionID, let format):
            let result = try await service.runMaintenance(actionID: actionID)
            let output = CLIMaintenanceOutput(
                metadata: CLICommandMetadata(command: "maintenance", timestamp: Date(), executedModules: []),
                result: result
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .maintenanceList(let format):
            let actions = await service.maintenanceActions()
            let output = CLIMaintenanceListOutput(
                metadata: CLICommandMetadata(command: "maintenance list", timestamp: Date(), executedModules: []),
                actions: actions
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .permissionsStatus(let format):
            let permissions = try await service.permissionsStatus()
            let output = CLIPermissionsOutput(
                metadata: CLICommandMetadata(command: "permissions status", timestamp: Date(), executedModules: permissions.modules.map(\.moduleID)),
                permissions: permissions
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .modulesList(let format):
            let modules = await service.listModules()
            let output = CLIModulesOutput(
                metadata: CLICommandMetadata(command: "modules list", timestamp: Date(), executedModules: modules.map(\.id)),
                modules: modules
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .version(let format):
            let output = CLIVersionOutput(
                metadata: CLICommandMetadata(command: "version", timestamp: Date(), executedModules: []),
                version: MacSweepVersion.current
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .space(let format):
            let disk = await service.diskUsage()
            let output = CLISpaceOutput(
                metadata: CLICommandMetadata(command: "space", timestamp: Date(), executedModules: []),
                disk: disk
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .spaceLens(let path, let depth, let format):
            let tree = try await service.diskTree(path: path, depth: depth)
            let output = CLISpaceLensOutput(
                metadata: CLICommandMetadata(command: "space lens", timestamp: Date(), executedModules: []),
                tree: tree
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .loginItemsList(let format):
            let report = await service.loginItems()
            let output = CLILoginItemsOutput(
                metadata: CLICommandMetadata(command: "login-items list", timestamp: Date(), executedModules: []),
                report: report
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .loginItemSet(let label, let enabled, let yes, let format):
            if !yes {
                let verb = enabled ? "Enable" : "Disable"
                try confirm("\(verb) login item '\(label)' (rewrites its launchd plist)?")
            }
            let result = try await service.setLoginItemEnabled(enabled, label: label)
            let output = CLILoginItemMutationOutput(
                metadata: CLICommandMetadata(command: "login-items \(enabled ? "enable" : "disable")", timestamp: Date(), executedModules: []),
                result: result
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .loginItemRemove(let label, let yes, let format):
            if !yes {
                try confirm("Remove login item '\(label)', moving its launchd plist to Trash?")
            }
            let result = try await service.removeLoginItem(label: label)
            let output = CLILoginItemMutationOutput(
                metadata: CLICommandMetadata(command: "login-items remove", timestamp: Date(), executedModules: []),
                result: result
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .uninstallList(let format):
            let report = await service.uninstallableApps()
            let output = CLIUninstallListOutput(
                metadata: CLICommandMetadata(command: "uninstall list", timestamp: Date(), executedModules: []),
                report: report
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .uninstall(let app, let yes, let format):
            // Resolve + price the removal up front so the confirmation prompt
            // (and the non-interactive refusal path) reflect the real footprint.
            // This also surfaces not-found / ambiguous errors before any prompt.
            let preview = try await service.uninstall(app: app, dryRun: true)
            if !yes {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                try confirm(
                    "Uninstall \(preview.appName) and \(preview.leftovers.count) leftover item(s), moving \(formatter.string(fromByteCount: preview.bytesFreed)) to Trash?"
                )
            }
            let result = try await service.uninstall(app: app, dryRun: false)
            let output = CLIUninstallOutput(
                metadata: CLICommandMetadata(command: "uninstall", timestamp: Date(), executedModules: []),
                result: result
            )
            try emit(output, format: format)
            return result.errors.isEmpty ? CLIExitCode.success.rawValue : CLIExitCode.generic.rawValue

        case .aiAnalysis(let deep, let format):
            let report = await service.cacheAnalysis(deep: deep)
            let output = CLIAIOutput(
                metadata: CLICommandMetadata(command: "ai", timestamp: Date(), executedModules: []),
                report: report
            )
            try emit(output, format: format)
            // Read-only scan: surface a soft failure (exit 1) only when errors
            // were collected (e.g. --deep requested but no key, or the API call
            // failed) so scripts can branch, while still emitting the findings.
            return report.errors.isEmpty ? CLIExitCode.success.rawValue : CLIExitCode.generic.rawValue

        case .malwareScan(let useAI, let format):
            let report = await service.scanMalware(useAI: useAI)
            let output = CLIMalwareOutput(
                metadata: CLICommandMetadata(command: "malware scan", timestamp: Date(), executedModules: []),
                report: report
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .homebrewOutdated(let format):
            let report = try await service.homebrewOutdated()
            let output = CLIHomebrewOutput(
                metadata: CLICommandMetadata(command: "homebrew outdated", timestamp: Date(), executedModules: []),
                report: report
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .homebrewUpgrade(let yes, let format):
            if !yes {
                try confirm("Upgrade all outdated Homebrew packages?")
            }
            let result = try await service.homebrewUpgrade()
            let output = CLIHomebrewUpgradeOutput(
                metadata: CLICommandMetadata(command: "homebrew upgrade", timestamp: Date(), executedModules: []),
                result: result
            )
            try emit(output, format: format)
            return CLIExitCode.success.rawValue

        case .shred(let path, let level, let yes, let format):
            if !yes {
                try confirm("Permanently shred '\(path)' at \(level) level? This cannot be undone.")
            }
            let result = try await service.shred(path: path, level: level)
            let output = CLIShredOutput(
                metadata: CLICommandMetadata(command: "shred", timestamp: Date(), executedModules: []),
                result: result
            )
            try emit(output, format: format)
            return result.success ? CLIExitCode.success.rawValue : CLIExitCode.generic.rawValue
        }
    }

    /// Maps a thrown error to a semantic exit code for the process.
    public static func exitCode(for error: Error) -> Int32 {
        if error is CLIParseError {
            return CLIExitCode.usage.rawValue
        }
        if let execError = error as? CLIExecutionError {
            switch execError {
            case .confirmationRequired:
                return CLIExitCode.confirmationRequired.rawValue
            case .cleanupCancelled:
                return CLIExitCode.generic.rawValue
            }
        }
        if let serviceError = error as? HeadlessServiceError {
            switch serviceError {
            case .pathNotFound, .homebrewNotInstalled, .appNotFound, .loginItemNotFound:
                return CLIExitCode.notFound.rawValue
            case .shredRefused, .appRunning:
                return CLIExitCode.refused.rawValue
            case .conflictingSelection, .invalidModules, .unknownMaintenanceAction, .ambiguousAppMatch, .loginItemAmbiguous:
                return CLIExitCode.usage.rawValue
            case .uninstallFailed, .loginItemMutationFailed:
                return CLIExitCode.generic.rawValue
            }
        }
        return CLIExitCode.generic.rawValue
    }

    private static func emitScanOutput(
        command: String,
        scan: HeadlessScanResult,
        cleanup: HeadlessCleanupResult?,
        format: CLIOutputFormat
    ) throws {
        let output = CLIScanOutput(
            metadata: CLICommandMetadata(command: command, timestamp: Date(), executedModules: scan.executedModules),
            permissions: scan.permissions,
            findings: scan.findings,
            summary: scan.summary,
            cleanup: cleanup
        )
        try emit(output, format: format)
    }

    private static func emit<T: Encodable>(_ value: T, format: CLIOutputFormat) throws {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(value)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        case .text:
            print(renderText(value))
        }
    }

    private static func renderText<T>(_ value: T) -> String {
        switch value {
        case let output as CLIScanOutput:
            let recommendedFindings = output.findings
                .filter(\.recommended)
                .sorted { lhs, rhs in
                    let lhsPriority = moduleDisplayPriority(lhs.module)
                    let rhsPriority = moduleDisplayPriority(rhs.module)

                    if lhsPriority == rhsPriority {
                        return lhs.size > rhs.size
                    }

                    return lhsPriority < rhsPriority
                }
            var lines = [
                "\(output.metadata.command) completed",
                "Modules: \(output.metadata.executedModules.joined(separator: ", "))",
                "Full Disk Access: \(output.permissions.fullDiskAccessGranted ? "granted" : "missing")",
                "Findings: \(output.summary.totalFindings)",
                "Reclaimable: \(ByteCountFormatter.string(fromByteCount: output.summary.reclaimableBytes, countStyle: .file))",
                "Score: \(output.summary.score)"
            ]

            if let cleanup = output.cleanup {
                lines.append(
                    "\(cleanup.dryRun ? "Preview" : "Cleanup"): \(cleanup.itemsProcessed) items, \(ByteCountFormatter.string(fromByteCount: cleanup.bytesFreed, countStyle: .file))"
                )
                if !cleanup.errors.isEmpty {
                    lines.append("Errors: \(cleanup.errors.count)")
                }
                if output.summary.recommendedFindings < output.summary.totalFindings {
                    lines.append("Auto-clean scope: only recommended items below are included in cleanup.")
                }
            }

            if !recommendedFindings.isEmpty {
                lines.append("")
                lines.append("Recommended cleanup items:")
                lines.append(contentsOf: recommendedFindings.prefix(10).map {
                    "  - [\($0.module)] \($0.path) (\(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)))"
                })
            }

            if !output.findings.isEmpty {
                lines.append("")
                lines.append("Largest findings (review-only items may appear here):")
                lines.append(contentsOf: output.findings.prefix(10).map {
                    "  - [\($0.module)] \($0.path) (\(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)))\($0.recommended ? " recommended" : "")"
                })
            }

            return lines.joined(separator: "\n")

        case let output as CLIModulesOutput:
            return output.modules.map {
                let permissions = $0.requiredPermissions.isEmpty
                    ? "none"
                    : $0.requiredPermissions.map(\.rawValue).joined(separator: ", ")
                return "\($0.id): \($0.name) [permissions: \(permissions)]"
            }.joined(separator: "\n")

        case let output as CLIPermissionsOutput:
            var lines = [
                "Full Disk Access: \(output.permissions.fullDiskAccessGranted ? "granted" : "missing")"
            ]
            lines.append(contentsOf: output.permissions.modules.map {
                let requirements = $0.requirements.isEmpty
                    ? "none"
                    : $0.requirements.map { "\($0.kind.rawValue)=\($0.granted ? "granted" : "missing")" }.joined(separator: ", ")
                return "\($0.moduleID): \(requirements)"
            })
            return lines.joined(separator: "\n")

        case let output as CLIMaintenanceOutput:
            var lines = [
                "\(output.result.action.id): \(output.result.message)",
                "Success: \(output.result.success ? "yes" : "no")"
            ]
            if output.result.bytesFreed > 0 {
                lines.append("Freed: \(ByteCountFormatter.string(fromByteCount: output.result.bytesFreed, countStyle: .file))")
            }
            return lines.joined(separator: "\n")

        case let output as CLIMaintenanceListOutput:
            if output.actions.isEmpty {
                return "No maintenance actions available."
            }
            return output.actions.map {
                "\($0.id): \($0.name)\($0.requiresAdmin ? " [admin]" : "") — \($0.description)"
            }.joined(separator: "\n")

        case let output as CLIVersionOutput:
            return "macsweep \(output.version)"

        case let output as CLISpaceOutput:
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return [
                "Disk usage:",
                "  Total: \(formatter.string(fromByteCount: output.disk.totalBytes))",
                "  Used:  \(formatter.string(fromByteCount: output.disk.usedBytes)) (\(String(format: "%.1f", output.disk.usedPercentage))%)",
                "  Free:  \(formatter.string(fromByteCount: output.disk.freeBytes)) (\(String(format: "%.1f", output.disk.freePercentage))%)"
            ].joined(separator: "\n")

        case let output as CLILoginItemsOutput:
            var lines = ["Login items: \(output.report.totalItems)"]
            lines.append(contentsOf: output.report.items.map {
                let state = $0.enabled ? "enabled" : "disabled"
                return "  [\($0.kind.rawValue)] \($0.name) (\(state)) — \($0.path)"
            })
            return lines.joined(separator: "\n")

        case let output as CLILoginItemMutationOutput:
            let result = output.result
            let state = result.removed
                ? "removed (moved to Trash)"
                : (result.enabled ? "enabled" : "disabled")
            return [
                "Login item: \(result.label) — \(state)",
                "Kind: \(result.kind.rawValue)",
                "Plist: \(result.plistPath)"
            ].joined(separator: "\n")

        case let output as CLISpaceLensOutput:
            let tree = output.tree
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            var lines = [
                "Space lens: \(tree.rootPath)",
                "Depth: \(tree.depth)",
                "Total: \(formatter.string(fromByteCount: tree.totalBytes))",
                ""
            ]
            appendDiskNodeLines(tree.root, indent: 0, formatter: formatter, into: &lines, isRoot: true)
            return lines.joined(separator: "\n")

        case let output as CLIUninstallListOutput:
            let report = output.report
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            var lines = [
                "Installed apps: \(report.totalApps)",
                "Total reclaimable: \(formatter.string(fromByteCount: report.totalReclaimableBytes))"
            ]
            lines.append(contentsOf: report.apps.map {
                "  \($0.name) (\($0.id)) — \(formatter.string(fromByteCount: $0.totalSize)) [\($0.leftoverCount) leftover(s)]"
            })
            return lines.joined(separator: "\n")

        case let output as CLIUninstallOutput:
            let result = output.result
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let status = result.dryRun ? "preview" : (result.removedApp ? "complete" : "failed")
            var lines = [
                "Uninstall: \(status) — \(result.appName) (\(result.appID))",
                "Bundle: \(result.bundlePath)",
                "Items: \(result.itemsProcessed) (\(result.leftoversRemoved) leftover(s) removed)",
                "Reclaimed: \(formatter.string(fromByteCount: result.bytesFreed))"
            ]
            if !result.leftovers.isEmpty {
                lines.append("Leftovers:")
                lines.append(contentsOf: result.leftovers.map {
                    "  - [\($0.type)] \($0.path) (\(formatter.string(fromByteCount: $0.size)))"
                })
            }
            if !result.errors.isEmpty {
                lines.append("Errors:")
                lines.append(contentsOf: result.errors.map { "  - \($0.path): \($0.message)" })
            }
            return lines.joined(separator: "\n")

        case let output as CLIAIOutput:
            let report = output.report
            var lines = [
                "Cache analysis: \(report.totalFindings) finding(s)",
                "Fast scan: \(report.fastScanCount)",
                "AI analysis: \(report.aiScanRequested ? (report.aiScanRan ? "ran" : "requested (unavailable)") : "off")"
            ]
            if !report.findings.isEmpty {
                lines.append("")
                lines.append("Findings:")
                lines.append(contentsOf: report.findings.map {
                    let reason = $0.reason.map { " — \($0)" } ?? ""
                    return "  - [\($0.category)] \($0.path) (\($0.sizeText)) {\($0.source)}\(reason)"
                })
            }
            if !report.errors.isEmpty {
                lines.append("")
                lines.append("Notes:")
                lines.append(contentsOf: report.errors.map { "  - \($0)" })
            }
            return lines.joined(separator: "\n")

        case let output as CLIMalwareOutput:
            let report = output.report
            var lines = [
                "Malware scan: \(report.isClean ? "clean" : "THREATS FOUND")",
                "XProtect: \(report.xprotectStatus)",
                "Scanned: \(report.totalScanned)",
                "AI analysis: \(report.aiAnalysisRequested ? "on" : "off")"
            ]
            if !report.findings.isEmpty {
                lines.append("")
                lines.append("Findings:")
                lines.append(contentsOf: report.findings.map {
                    "  - [\($0.threatLevel)] \($0.category): \($0.path)"
                })
            }
            return lines.joined(separator: "\n")

        case let output as CLIHomebrewOutput:
            let report = output.report
            if report.outdatedCount == 0 {
                return "Homebrew: all packages up to date."
            }
            var lines = ["Homebrew: \(report.outdatedCount) outdated"]
            lines.append(contentsOf: report.packages.map {
                "  \($0.name): \($0.currentVersion) → \($0.latestVersion)"
            })
            return lines.joined(separator: "\n")

        case let output as CLIHomebrewUpgradeOutput:
            let result = output.result
            var lines = ["Homebrew upgrade: \(result.upgraded ? "complete" : "failed")"]
            if result.remainingOutdated.isEmpty {
                lines.append("All packages up to date.")
            } else {
                lines.append("Remaining outdated: \(result.remainingOutdated.count)")
                lines.append(contentsOf: result.remainingOutdated.map {
                    "  \($0.name): \($0.currentVersion) → \($0.latestVersion)"
                })
            }
            return lines.joined(separator: "\n")

        case let output as CLIShredOutput:
            let result = output.result
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            var lines = [
                "Shred: \(result.success ? "complete" : "failed") — \(result.path)",
                "Level: \(result.level)\(result.isDirectory ? " (directory)" : "")",
                "Files shredded: \(result.filesShredded)",
                "Bytes shredded: \(formatter.string(fromByteCount: result.bytesShredded))"
            ]
            if !result.errors.isEmpty {
                lines.append("Errors:")
                lines.append(contentsOf: result.errors.map { "  - \($0)" })
            }
            return lines.joined(separator: "\n")

        default:
            return String(describing: value)
        }
    }

    private static func confirmCleanup(_ preview: HeadlessCleanupResult) throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIExecutionError.confirmationRequired
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        print(
            "Proceed to clean \(preview.itemsProcessed) items and reclaim \(formatter.string(fromByteCount: preview.bytesFreed))? [y/N]",
            terminator: " "
        )

        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response == "y" || response == "yes" else {
            throw CLIExecutionError.cleanupCancelled
        }
    }

    /// Generic interactive confirmation gate for destructive/external commands.
    /// Refuses (rather than silently proceeding) when stdin is not a TTY and
    /// `--yes` was not supplied.
    private static func confirm(_ message: String) throws {
        guard isatty(STDIN_FILENO) != 0 else {
            throw CLIExecutionError.confirmationRequired
        }
        print("\(message) [y/N]", terminator: " ")
        guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              response == "y" || response == "yes" else {
            throw CLIExecutionError.cleanupCancelled
        }
    }

    /// Per-node cap on children rendered in the text space-lens tree, so a wide
    /// directory does not flood the terminal. JSON output is uncapped.
    private static let diskLensChildCap = 15

    /// Recursively render a disk node and its (size-sorted) children as an
    /// indented tree. The root node's header is printed separately, so the root
    /// itself is skipped and its children start at indent 0.
    private static func appendDiskNodeLines(
        _ node: HeadlessDiskNode,
        indent: Int,
        formatter: ByteCountFormatter,
        into lines: inout [String],
        isRoot: Bool
    ) {
        if !isRoot {
            let pad = String(repeating: "  ", count: indent)
            let glyph = node.isDirectory ? "▸" : "·"
            lines.append("\(pad)\(glyph) \(node.name) (\(formatter.string(fromByteCount: node.size)))")
        }

        let childIndent = isRoot ? 0 : indent + 1
        for child in node.children.prefix(diskLensChildCap) {
            appendDiskNodeLines(child, indent: childIndent, formatter: formatter, into: &lines, isRoot: false)
        }
        if node.children.count > diskLensChildCap {
            let pad = String(repeating: "  ", count: childIndent)
            lines.append("\(pad)… \(node.children.count - diskLensChildCap) more")
        }
    }

    private static func moduleDisplayPriority(_ moduleID: String) -> Int {
        switch moduleID {
        case "trash-bins": return 0
        case "system-cache": return 1
        case "cloud-cleanup": return 2
        case "mail-attachments": return 3
        case "dev-tools": return 4
        default: return 10
        }
    }
}
