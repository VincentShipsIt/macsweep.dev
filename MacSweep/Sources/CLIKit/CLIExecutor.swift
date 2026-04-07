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

enum CLIExecutionError: Error, LocalizedError {
    case confirmationRequired
    case cleanupCancelled

    var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Refusing destructive cleanup without --yes in non-interactive mode."
        case .cleanupCancelled:
            return "Cleanup cancelled."
        }
    }
}

public enum CLIExecutor {
    @discardableResult
    public static func run(command: CLICommand) async throws -> Int32 {
        let service = MacSweepHeadlessService()

        switch command {
        case .help:
            print(CLIHelp.text)
            return 0

        case .scan(let request, let format):
            let result = try await service.scan(request: request)
            try emitScanOutput(
                command: "scan",
                scan: result,
                cleanup: nil,
                format: format
            )
            return 0

        case .dryRun(let request, let format):
            let plan = try await service.prepareCleanup(request: request)
            try emitScanOutput(
                command: "dry-run",
                scan: plan.scan,
                cleanup: plan.cleanupPreview,
                format: format
            )
            return 0

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
            return 0

        case .maintenance(let actionID, let format):
            let result = try await service.runMaintenance(actionID: actionID)
            let output = CLIMaintenanceOutput(
                metadata: CLICommandMetadata(command: "maintenance", timestamp: Date(), executedModules: []),
                result: result
            )
            try emit(output, format: format)
            return 0

        case .permissionsStatus(let format):
            let permissions = try await service.permissionsStatus()
            let output = CLIPermissionsOutput(
                metadata: CLICommandMetadata(command: "permissions status", timestamp: Date(), executedModules: permissions.modules.map(\.moduleID)),
                permissions: permissions
            )
            try emit(output, format: format)
            return 0

        case .modulesList(let format):
            let modules = await service.listModules()
            let output = CLIModulesOutput(
                metadata: CLICommandMetadata(command: "modules list", timestamp: Date(), executedModules: modules.map(\.id)),
                modules: modules
            )
            try emit(output, format: format)
            return 0
        }
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
