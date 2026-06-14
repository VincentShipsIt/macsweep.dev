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
    private let engine: ScanEngine

    public init() {
        self.engine = ScanEngine()
    }

    /// Test seam: inject a ScanEngine with stub modules to exercise partial-scan
    /// surfacing (and other engine-backed paths) without touching real modules.
    init(engine: ScanEngine) {
        self.engine = engine
    }

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
        let scanFailures: [ModuleScanFailure]
        if request.smartCare {
            items = try await engine.smartCareScan()
            scanFailures = []
        } else {
            // Use the diagnostics variant so a module that throws is captured as a
            // failure instead of silently dropped — the caller surfaces it as a
            // partial scan (and the CLI turns it into a nonzero exit code).
            let partial = await engine.scanWithDiagnostics(modules: executedModuleIDs)
            items = partial.items
            scanFailures = partial.failures
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
                // Per-module scan failures, surfaced so a partial scan is visible
                // rather than masquerading as a smaller-but-complete result. `path`
                // carries the module id (the locus of the failure) since a scan
                // error is not tied to a single filesystem path.
                errors: scanFailures.map {
                    HeadlessCleanupError(path: $0.moduleID, message: $0.message)
                }
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

    /// Enable or disable a launch agent/daemon by its launchd Label.
    public func setLoginItemEnabled(_ enabled: Bool, label: String) async throws -> HeadlessLoginItemMutationResult {
        do {
            let outcome = try await LoginItemController().setEnabled(enabled, label: label)
            return HeadlessLoginItemMutationResult(
                label: outcome.label,
                plistPath: outcome.plistPath,
                kind: outcome.kind,
                action: enabled ? "enable" : "disable",
                enabled: outcome.enabled,
                removed: false
            )
        } catch let error as LoginItemController.MutationError {
            throw Self.mapLoginItemError(error, label: label)
        }
    }

    /// Move a launch agent/daemon plist to the Trash by its launchd Label.
    public func removeLoginItem(label: String) async throws -> HeadlessLoginItemMutationResult {
        do {
            let outcome = try await LoginItemController().remove(label: label)
            return HeadlessLoginItemMutationResult(
                label: outcome.label,
                plistPath: outcome.plistPath,
                kind: outcome.kind,
                action: "remove",
                enabled: false,
                removed: true
            )
        } catch let error as LoginItemController.MutationError {
            throw Self.mapLoginItemError(error, label: label)
        }
    }

    private static func mapLoginItemError(_ error: LoginItemController.MutationError, label: String) -> HeadlessServiceError {
        switch error {
        case .notFound:
            return .loginItemNotFound(label)
        case .ambiguous(let paths):
            return .loginItemAmbiguous(label, paths)
        case .failed(let reason):
            return .loginItemMutationFailed(reason)
        }
    }

    // MARK: - Space Lens (disk tree)

    /// Build a depth-bounded disk-usage tree rooted at `path` (defaults to the
    /// user's home directory). Read-only — sizing and enumeration only.
    public func diskTree(path: String?, depth: Int) async throws -> HeadlessDiskTree {
        let expanded: String
        if let path, !path.isEmpty {
            expanded = (path as NSString).expandingTildeInPath
        } else {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        }
        let url = URL(fileURLWithPath: expanded)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw HeadlessServiceError.pathNotFound(expanded)
        }

        // Defensive clamp; the parser already validates 1...6.
        let clampedDepth = min(max(depth, 1), 6)
        let node = try await DiskAnalyzer.buildDiskTree(at: url, maxDepth: clampedDepth)

        return HeadlessDiskTree(
            rootPath: url.path,
            depth: clampedDepth,
            totalBytes: node.size,
            root: Self.serializeDiskNode(node)
        )
    }

    private static func serializeDiskNode(_ node: DiskNode) -> HeadlessDiskNode {
        HeadlessDiskNode(
            name: node.name,
            path: node.url.path,
            size: node.size,
            isDirectory: node.isDirectory,
            lastModified: node.lastModified,
            childCount: node.children.count,
            children: node.children.map { serializeDiskNode($0) }
        )
    }

    // MARK: - App Uninstall

    /// Enumerate installed apps with their leftover footprint, sorted by total
    /// reclaimable size. Read-only — discovery + per-app leftover scan, no removal.
    public func uninstallableApps() async -> HeadlessUninstallableAppsReport {
        let discovery = AppDiscovery()
        var apps = await discovery.installedApps()
        let scanner = LeftoverScanner()
        for index in apps.indices {
            apps[index].leftovers = await scanner.findLeftovers(for: apps[index])
        }

        let headless = apps
            .map { Self.serializeInstalledApp($0) }
            .sorted { $0.totalSize > $1.totalSize }
        let totalReclaimable = headless.reduce(Int64(0)) { $0 + $1.totalSize }

        return HeadlessUninstallableAppsReport(
            totalApps: headless.count,
            totalReclaimableBytes: totalReclaimable,
            apps: headless
        )
    }

    /// Resolve `query` to a single installed app and either preview (dryRun) or
    /// execute its uninstall (bundle + leftovers, all moved to Trash).
    public func uninstall(app query: String, dryRun: Bool) async throws -> HeadlessUninstallResult {
        let discovery = AppDiscovery()
        let apps = await discovery.installedApps()
        var target = try Self.matchApp(query: query, in: apps)

        // Always populate leftovers before previewing or removing.
        let scanner = LeftoverScanner()
        target.leftovers = await scanner.findLeftovers(for: target)
        let leftoverDTOs = target.leftovers.map { Self.serializeLeftover($0) }

        if dryRun {
            return HeadlessUninstallResult(
                appID: target.id,
                appName: target.name,
                bundlePath: target.bundlePath.path,
                dryRun: true,
                removedApp: false,
                itemsProcessed: 1 + target.leftovers.count,
                bytesFreed: target.totalSize,
                leftoversRemoved: 0,
                leftovers: leftoverDTOs,
                errors: []
            )
        }

        do {
            let result = try await AppUninstaller().uninstall(target, includeLeftovers: true)
            // uninstall() throws if the bundle can't be removed, so reaching here
            // means the app itself went to Trash; remaining items are leftovers.
            let leftoversRemoved = max(0, result.itemsProcessed - 1)
            return HeadlessUninstallResult(
                appID: target.id,
                appName: target.name,
                bundlePath: target.bundlePath.path,
                dryRun: false,
                removedApp: true,
                itemsProcessed: result.itemsProcessed,
                bytesFreed: result.bytesFreed,
                leftoversRemoved: leftoversRemoved,
                leftovers: leftoverDTOs,
                errors: result.errors.map {
                    HeadlessCleanupError(path: $0.path.path, message: $0.message)
                }
            )
        } catch let error as UninstallError {
            switch error {
            case .appRunning(let name):
                throw HeadlessServiceError.appRunning(name)
            case .cannotRemoveApp(_, let underlying):
                throw HeadlessServiceError.uninstallFailed(underlying.localizedDescription)
            case .insufficientPermissions(let name):
                throw HeadlessServiceError.uninstallFailed(
                    "Administrator privileges required to remove \(name) from /Applications."
                )
            }
        }
    }

    /// Match precedence: exact bundle id → exact display name → single substring
    /// (on name or bundle id). Multiple matches at name/substring level are
    /// ambiguous; zero matches are not found.
    private static func matchApp(query: String, in apps: [InstalledApp]) throws -> InstalledApp {
        if let byID = apps.first(where: { $0.id.caseInsensitiveCompare(query) == .orderedSame }) {
            return byID
        }

        let exactNames = apps.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if exactNames.count == 1 { return exactNames[0] }
        if exactNames.count > 1 {
            throw HeadlessServiceError.ambiguousAppMatch(query, exactNames.map { "\($0.name) (\($0.id))" })
        }

        let substring = apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.id.localizedCaseInsensitiveContains(query)
        }
        if substring.count == 1 { return substring[0] }
        if substring.count > 1 {
            throw HeadlessServiceError.ambiguousAppMatch(query, substring.map { "\($0.name) (\($0.id))" })
        }

        throw HeadlessServiceError.appNotFound(query)
    }

    private static func serializeLeftover(_ leftover: AppLeftover) -> HeadlessAppLeftover {
        HeadlessAppLeftover(path: leftover.path.path, size: leftover.size, type: leftover.type.rawValue)
    }

    private static func serializeInstalledApp(_ app: InstalledApp) -> HeadlessInstalledApp {
        HeadlessInstalledApp(
            id: app.id,
            name: app.name,
            bundlePath: app.bundlePath.path,
            version: app.version,
            bundleSize: app.bundleSize,
            leftoverBytes: app.leftoverSize,
            leftoverCount: app.leftovers.count,
            totalSize: app.totalSize,
            lastUsed: app.lastUsed,
            leftovers: app.leftovers.map { serializeLeftover($0) }
        )
    }

    // MARK: - Cache Analysis

    /// Deterministic developer-cache scan plus, when `deep` is true and a stored
    /// Anthropic key exists, an AI semantic pass. Read-only — never deletes.
    public func cacheAnalysis(deep: Bool) async -> HeadlessCacheReport {
        let analyzer = CacheAnalyzer()
        let result = await analyzer.analyze(deep: deep)
        let findings = result.findings.map { finding in
            HeadlessCacheFinding(
                path: finding.path,
                sizeText: finding.sizeText,
                category: finding.category.rawValue,
                regeneratesAutomatically: finding.regeneratesAutomatically,
                source: finding.source,
                reason: finding.reason
            )
        }
        return HeadlessCacheReport(
            fastScanCount: result.fastCount,
            aiScanRequested: deep,
            aiScanRan: result.aiRan,
            totalFindings: findings.count,
            findings: findings,
            errors: result.errors
        )
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
