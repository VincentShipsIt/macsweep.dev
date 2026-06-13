import Foundation

private enum ModulePermissionCatalog {
    static func requiredPermissions(for moduleID: String) -> [HeadlessPermissionKind] {
        switch moduleID {
        case "browser-safari", "mail-attachments", "privacy":
            return [.fullDiskAccess]
        default:
            return []
        }
    }
}

public actor MacSweepHeadlessService {
    private let engine = ScanEngine()

    public init() {}

    public func listModules() async -> [HeadlessModuleDescriptor] {
        let modules = await engine.registeredModules()
        return modules.map { module in
            HeadlessModuleDescriptor(
                id: module.id,
                name: module.name,
                description: module.description,
                requiredPermissions: ModulePermissionCatalog.requiredPermissions(for: module.id)
            )
        }
        .sorted { $0.id < $1.id }
    }

    public func permissionsStatus(moduleIDs: [String]? = nil) async throws -> HeadlessPermissionStatusReport {
        let modules = try await resolveModules(moduleIDs: moduleIDs, smartCare: false)
        return permissionReport(for: modules)
    }

    public func maintenanceActions() -> [HeadlessMaintenanceActionDescriptor] {
        MaintenanceTask.allTasks.map {
            HeadlessMaintenanceActionDescriptor(
                id: $0.id,
                name: $0.name,
                description: $0.description,
                requiresAdmin: $0.requiresAdmin
            )
        }
    }

    public func runMaintenance(actionID: String) async throws -> HeadlessMaintenanceRunResult {
        guard let task = MaintenanceTask.allTasks.first(where: { $0.id == actionID }) else {
            throw HeadlessServiceError.unknownMaintenanceAction(actionID)
        }

        let result = try await task.action()
        return HeadlessMaintenanceRunResult(
            action: HeadlessMaintenanceActionDescriptor(
                id: task.id,
                name: task.name,
                description: task.description,
                requiresAdmin: task.requiresAdmin
            ),
            success: result.success,
            message: result.message,
            bytesFreed: result.bytesFreed
        )
    }

    public func scan(request: HeadlessSelectionRequest = .init()) async throws -> HeadlessScanResult {
        let selection = try await collectSelection(for: request)
        return selection.scanResult
    }

    public func prepareCleanup(request: HeadlessSelectionRequest) async throws -> HeadlessPreparedCleanupPlan {
        let selection = try await collectSelection(for: request)
        let preview = try await engine.clean(items: selection.selectedItems, dryRun: true)
        return HeadlessPreparedCleanupPlan(
            scan: selection.scanResult,
            cleanupPreview: serializeCleanupResult(preview, dryRun: true),
            selectedItems: selection.selectedItems
        )
    }

    public func executeCleanup(_ plan: HeadlessPreparedCleanupPlan) async throws -> HeadlessApplyResult {
        let result = try await engine.clean(items: plan.selectedItems, dryRun: false)
        return HeadlessApplyResult(
            scan: plan.scan,
            cleanup: serializeCleanupResult(result, dryRun: false)
        )
    }

    private func collectSelection(for request: HeadlessSelectionRequest) async throws -> SelectionSnapshot {
        let modules = try await resolveModules(moduleIDs: request.moduleIDs, smartCare: request.smartCare)
        let executedModuleIDs = modules.map(\.id)

        let items: [CleanupItem]
        if request.smartCare {
            items = try await engine.smartCareScan()
        } else {
            items = try await engine.scan(modules: executedModuleIDs)
        }

        let diskUsage = await DiskUsage.current()
        let smartCareSummary = SmartCareAnalyzer().summarize(items: items, diskUsage: diskUsage)
        let recommendedIDs = smartCareSummary.recommendedCleanupItemIDs
        let selectedItems = request.smartCare
            ? items.filter { recommendedIDs.contains($0.id) }
            : items

        let findings = items.map { item in
            HeadlessFinding(
                id: item.id.uuidString,
                module: item.module,
                moduleName: item.moduleName,
                path: item.path.path,
                size: item.size,
                type: item.type.rawValue,
                lastModified: item.lastModified,
                recommended: recommendedIDs.contains(item.id)
            )
        }

        let recommendedItems = items.filter { recommendedIDs.contains($0.id) }
        let scanResult = HeadlessScanResult(
            executedModules: executedModuleIDs,
            permissions: permissionReport(for: modules),
            findings: findings.sorted { $0.size > $1.size },
            summary: HeadlessSummary(
                score: smartCareSummary.score,
                reclaimableBytes: smartCareSummary.reclaimableBytes,
                totalFindings: items.count,
                issueCount: smartCareSummary.issueCount,
                categoryCount: smartCareSummary.findings.count,
                recommendedFindings: recommendedItems.count,
                recommendedBytes: recommendedItems.reduce(0) { $0 + $1.size },
                errors: []
            )
        )

        return SelectionSnapshot(scanResult: scanResult, selectedItems: selectedItems)
    }

    private func resolveModules(moduleIDs: [String]?, smartCare: Bool) async throws -> [any ScanModule] {
        if smartCare, moduleIDs != nil {
            throw HeadlessServiceError.conflictingSelection
        }

        let allModules = await engine.registeredModules()
        let moduleMap = Dictionary(uniqueKeysWithValues: allModules.map { ($0.id, $0) })

        let resolvedIDs: [String]
        if smartCare {
            resolvedIDs = SmartCareDefaults.moduleIDs.filter { moduleMap[$0] != nil }
        } else if let moduleIDs {
            let invalid = moduleIDs.filter { moduleMap[$0] == nil }
            if !invalid.isEmpty {
                throw HeadlessServiceError.invalidModules(invalid)
            }
            resolvedIDs = moduleIDs
        } else {
            resolvedIDs = allModules.map(\.id)
        }

        return resolvedIDs.compactMap { moduleMap[$0] }
    }

    private func permissionReport(for modules: [any ScanModule]) -> HeadlessPermissionStatusReport {
        let hasFullDiskAccess = FullDiskAccess.hasAccess

        let moduleStatuses = modules.map { module in
            let requirements = ModulePermissionCatalog.requiredPermissions(for: module.id).map { kind in
                HeadlessPermissionRequirement(
                    kind: kind,
                    granted: kind == .fullDiskAccess ? hasFullDiskAccess : false
                )
            }

            return HeadlessModulePermissionStatus(
                moduleID: module.id,
                moduleName: module.name,
                requirements: requirements,
                allRequirementsSatisfied: requirements.allSatisfy(\.granted)
            )
        }

        return HeadlessPermissionStatusReport(
            fullDiskAccessGranted: hasFullDiskAccess,
            modules: moduleStatuses.sorted { $0.moduleID < $1.moduleID }
        )
    }

    private func serializeCleanupResult(_ result: CleanupResult, dryRun: Bool) -> HeadlessCleanupResult {
        HeadlessCleanupResult(
            dryRun: dryRun,
            itemsProcessed: result.itemsProcessed,
            bytesFreed: result.bytesFreed,
            errors: result.errors.map {
                HeadlessCleanupError(path: $0.path.path, message: $0.message)
            }
        )
    }

    // MARK: - Disk Usage

    public func diskUsage() async -> HeadlessDiskUsage {
        guard let usage = await DiskUsage.current() else {
            return HeadlessDiskUsage(
                totalBytes: 0, usedBytes: 0, freeBytes: 0,
                usedPercentage: 0, freePercentage: 0
            )
        }
        // DiskUsage exposes used/free as 0–1 fractions; surface them as 0–100
        // percentages so JSON and text consumers get a conventional number.
        return HeadlessDiskUsage(
            totalBytes: usage.total,
            usedBytes: usage.used,
            freeBytes: usage.free,
            usedPercentage: usage.usedPercentage * 100,
            freePercentage: usage.freePercentage * 100
        )
    }

    // MARK: - Login Items

    public func loginItems() async -> HeadlessLoginItemsReport {
        let items = await LoginItemEnumerator().enumerate()
        return HeadlessLoginItemsReport(totalItems: items.count, items: items)
    }

    // MARK: - Malware Scan (delegates to @MainActor service)

    public func scanMalware(useAI: Bool) async -> HeadlessMalwareScanReport {
        await runMalwareScanOnMain(useAI: useAI)
    }

    // MARK: - Homebrew (delegates to @MainActor service)

    public func homebrewOutdated() async throws -> HeadlessHomebrewReport {
        try await runHomebrewOutdatedOnMain()
    }

    public func homebrewUpgrade() async throws -> HeadlessHomebrewUpgradeResult {
        try await runHomebrewUpgradeOnMain()
    }

    // MARK: - Shred

    public func shred(path: String, level: String) async throws -> HeadlessShredResult {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw HeadlessServiceError.pathNotFound(expanded)
        }

        // Apply the same blocklist the GUI shredder uses before any overwrite:
        // refuses symlinks, the home/root dirs, whole user folders, and
        // system/credential/cloud roots.
        let validation = SafetyChecker().validateForShred(url)
        guard validation.isSafe else {
            throw HeadlessServiceError.shredRefused(validation.reason ?? "protected path")
        }

        let shredLevel = Self.shredLevel(from: level)

        if isDir.boolValue {
            let result = try await SecureDelete.shredDirectory(at: url, level: shredLevel)
            return HeadlessShredResult(
                path: expanded,
                level: level.lowercased(),
                isDirectory: true,
                filesShredded: result.filesShredded,
                bytesShredded: result.bytesShredded,
                success: result.success,
                errors: result.errors.map { $0.localizedDescription }
            )
        } else {
            // Read size before shredding — the file is gone afterward.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int64) ?? 0
            try await SecureDelete.shred(file: url, level: shredLevel)
            return HeadlessShredResult(
                path: expanded,
                level: level.lowercased(),
                isDirectory: false,
                filesShredded: 1,
                bytesShredded: size,
                success: true,
                errors: []
            )
        }
    }

    /// Map a lowercase CLI level string to the capitalized-rawValue ShredLevel.
    private static func shredLevel(from raw: String) -> SecureDelete.ShredLevel {
        switch raw.lowercased() {
        case "quick": return .quick
        case "secure": return .secure
        case "paranoid": return .paranoid
        default: return .standard
        }
    }
}

private struct SelectionSnapshot {
    let scanResult: HeadlessScanResult
    let selectedItems: [CleanupItem]
}

// MARK: - @MainActor bridges to ObservableObject services
//
// MalwareScannerService and HomebrewService are @MainActor classes. These
// file-private free functions hop to the main actor, run the service, and
// return ONLY Sendable Headless* structs — so the actor above never touches a
// non-Sendable @MainActor object across isolation boundaries.

@MainActor
private func runMalwareScanOnMain(useAI: Bool) async -> HeadlessMalwareScanReport {
    let service = MalwareScannerService()
    await service.runScan(useAI: useAI)
    let result = service.scanResult
    let findings = (result?.findings ?? []).map { finding in
        HeadlessThreatFinding(
            path: finding.path,
            category: finding.category.rawValue,
            threatLevel: finding.threatLevel.rawValue,
            description: finding.description,
            aiExplanation: finding.aiExplanation,
            remediation: finding.remediation
        )
    }
    return HeadlessMalwareScanReport(
        scannedAt: result?.scannedAt ?? Date(),
        totalScanned: result?.totalScanned ?? 0,
        isClean: result?.isClean ?? true,
        xprotectStatus: service.xprotectStatus,
        aiAnalysisRequested: useAI,
        findings: findings
    )
}

@MainActor
private func runHomebrewOutdatedOnMain() async throws -> HeadlessHomebrewReport {
    let service = HomebrewService()
    guard service.brewExists() else {
        throw HeadlessServiceError.homebrewNotInstalled
    }
    await service.checkOutdated()
    if service.error == "brew_not_found" {
        throw HeadlessServiceError.homebrewNotInstalled
    }
    let packages = service.packages.map { package in
        HeadlessBrewPackage(
            name: package.name,
            currentVersion: package.currentVersion,
            latestVersion: package.latestVersion
        )
    }
    return HeadlessHomebrewReport(outdatedCount: packages.count, packages: packages)
}

@MainActor
private func runHomebrewUpgradeOnMain() async throws -> HeadlessHomebrewUpgradeResult {
    let service = HomebrewService()
    guard service.brewExists() else {
        throw HeadlessServiceError.homebrewNotInstalled
    }
    await service.upgradeAll()
    let remaining = service.packages.map { package in
        HeadlessBrewPackage(
            name: package.name,
            currentVersion: package.currentVersion,
            latestVersion: package.latestVersion
        )
    }
    return HeadlessHomebrewUpgradeResult(
        upgraded: true,
        log: service.upgradeLog,
        remainingOutdated: remaining
    )
}
