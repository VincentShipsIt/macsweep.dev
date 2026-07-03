import Foundation
import AppKit

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
    public func diskTree(path: String?, depth: Int, minSize: Int64 = 0) async throws -> HeadlessDiskTree {
        let expanded: String
        if let path, !path.isEmpty {
            expanded = path.expandingTilde
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
            // The root is always emitted; `minSize` prunes its descendants so the
            // serialized tree only carries branches worth a human/agent's attention.
            root: Self.serializeDiskNode(node, minSize: minSize)
        )
    }

    private static func serializeDiskNode(_ node: DiskNode, minSize: Int64) -> HeadlessDiskNode {
        // Parent size >= child size, so dropping children below the threshold can
        // never hide a large descendant — the whole subtree under a small dir is
        // itself small. Keeps large branches, prunes the long tail of noise.
        let keptChildren = minSize > 0 ? node.children.filter { $0.size >= minSize } : node.children
        return HeadlessDiskNode(
            name: node.name,
            path: node.url.path,
            size: node.size,
            isDirectory: node.isDirectory,
            fileType: node.isDirectory ? "directory" : Self.fileType(for: node.url),
            lastModified: node.lastModified,
            childCount: keptChildren.count,
            children: keptChildren.map { serializeDiskNode($0, minSize: minSize) }
        )
    }

    /// Lowercased file extension, or "file" when the leaf has none.
    private static func fileType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "file" : ext
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
            case .blockedBySafety(let name):
                throw HeadlessServiceError.uninstallFailed(
                    "Refusing to uninstall \(name): the app bundle failed a safety check (unexpected location or symlink)."
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

    public func homebrewCleanup() async throws -> HeadlessHomebrewCleanupResult {
        try await runHomebrewCleanupOnMain()
    }

    public func homebrewLeaves() async throws -> HeadlessHomebrewLeavesReport {
        try await runHomebrewLeavesOnMain()
    }

    // MARK: - Schedule (shared suite domain with the GUI scheduler)

    /// Report the configured background-scan interval and next run time. The plain
    /// `SchedulerConfig` value type is `Sendable` and touches no main-actor state, so
    /// it is used directly inside the actor — no main hop needed.
    public func scheduleStatus() async -> HeadlessScheduleReport {
        let config = SchedulerConfig()
        return HeadlessScheduleReport(
            intervalDays: config.intervalDays,
            intervalSeconds: Int(config.intervalSeconds),
            nextScheduledScan: config.nextScheduledScan,
            minIntervalDays: SchedulerConfig.minIntervalDays,
            maxIntervalDays: SchedulerConfig.maxIntervalDays
        )
    }

    /// Set the interval and re-anchor the next scan one interval out so the new
    /// cadence takes effect immediately rather than at the previously-stored date.
    public func setScheduleInterval(days: Int) async -> HeadlessScheduleReport {
        let config = SchedulerConfig()
        config.setIntervalDays(days)
        config.setNextScheduledScan(Date(timeIntervalSinceNow: config.intervalSeconds))
        return HeadlessScheduleReport(
            intervalDays: config.intervalDays,
            intervalSeconds: Int(config.intervalSeconds),
            nextScheduledScan: config.nextScheduledScan,
            minIntervalDays: SchedulerConfig.minIntervalDays,
            maxIntervalDays: SchedulerConfig.maxIntervalDays
        )
    }

    // MARK: - Self-update (delegates to @MainActor service)

    public func selfUpdate(apply: Bool) async throws -> HeadlessSelfUpdateResult {
        try await runSelfUpdateOnMain(apply: apply)
    }

    // MARK: - Shred

    public func shred(path: String, level: String) async throws -> HeadlessShredResult {
        let expanded = path.expandingTilde
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

    // MARK: - Network: WiFi

    /// Saved (preferred) WiFi networks plus the currently-connected SSID.
    /// Backed by `WiFiNetworkManager` (synchronous `networksetup` calls); safe to
    /// run directly on the actor since it touches no @MainActor state.
    public func wifiNetworks() async -> HeadlessWiFiReport {
        let current = WiFiNetworkManager.getCurrentSSID()
        let saved = WiFiNetworkManager.savedNetworks()
        let networks = saved.map {
            HeadlessWiFiNetwork(ssid: $0.ssid, isConnected: $0.isCurrentlyConnected)
        }
        return HeadlessWiFiReport(
            currentSSID: current,
            totalNetworks: networks.count,
            networks: networks
        )
    }

    /// Forget a saved WiFi network by exact SSID. Throws `wifiNetworkNotFound`
    /// when no preferred network matches; maps an underlying removal failure to
    /// `networkOperationFailed`.
    public func removeWiFiNetwork(ssid: String) async throws -> HeadlessWiFiRemoveResult {
        let saved = WiFiNetworkManager.savedNetworks()
        guard saved.contains(where: { $0.ssid == ssid }) else {
            throw HeadlessServiceError.wifiNetworkNotFound(ssid)
        }
        do {
            try WiFiNetworkManager.removeNetwork(ssid)
        } catch {
            throw HeadlessServiceError.networkOperationFailed(error.localizedDescription)
        }
        return HeadlessWiFiRemoveResult(ssid: ssid, removed: true)
    }

    // MARK: - Network: SSH Known Hosts

    /// Parsed ~/.ssh/known_hosts entries (empty when the file is absent).
    public func sshKnownHosts() async -> HeadlessSSHReport {
        let hosts = SSHKnownHostsManager.getKnownHosts()
        let mapped = hosts.map {
            HeadlessSSHKnownHost(host: $0.host, algorithm: $0.algorithm, isHashed: $0.isHashed)
        }
        return HeadlessSSHReport(totalHosts: mapped.count, hosts: mapped)
    }

    /// Remove every known_hosts entry whose displayed host matches `host`.
    /// Throws `sshHostNotFound` when nothing matches.
    public func removeSSHKnownHost(host: String) async throws -> HeadlessSSHRemoveResult {
        let all = SSHKnownHostsManager.getKnownHosts()
        let matches = all.filter { $0.host == host }
        guard !matches.isEmpty else {
            throw HeadlessServiceError.sshHostNotFound(host)
        }
        do {
            for match in matches {
                try SSHKnownHostsManager.removeHost(match)
            }
        } catch {
            throw HeadlessServiceError.networkOperationFailed(error.localizedDescription)
        }
        return HeadlessSSHRemoveResult(target: host, removedCount: matches.count, clearedAll: false)
    }

    /// Clear all known_hosts entries (the manager backs up first). No-ops cleanly
    /// when the file is empty/absent — `clearAll()` would otherwise throw on a
    /// missing source file.
    public func clearSSHKnownHosts() async throws -> HeadlessSSHRemoveResult {
        let all = SSHKnownHostsManager.getKnownHosts()
        guard !all.isEmpty else {
            return HeadlessSSHRemoveResult(target: "all", removedCount: 0, clearedAll: true)
        }
        do {
            try SSHKnownHostsManager.clearAll()
        } catch {
            throw HeadlessServiceError.networkOperationFailed(error.localizedDescription)
        }
        return HeadlessSSHRemoveResult(target: "all", removedCount: all.count, clearedAll: true)
    }

    // MARK: - Processes

    /// Running processes sorted by `memory` (default), `cpu`, or `name`.
    public func listProcesses(sort: String) async -> HeadlessProcessReport {
        await runProcessListOnMain(sort: sort)
    }

    /// Quit a process resolved by PID or case-insensitive name substring.
    /// Refuses pid<=1 and our own pid; throws `processNotFound` / `processAmbiguous`
    /// on resolution failures.
    public func quitProcess(target: String, force: Bool) async throws -> HeadlessProcessQuitResult {
        try await runProcessQuitOnMain(target: target, force: force)
    }

    // MARK: - Privacy Actions

    /// Run a privacy cleanup action backed by `PrivacyActions`.
    public func privacyAction(_ action: String) async throws -> HeadlessPrivacyActionResult {
        try await runPrivacyActionOnMain(action: action)
    }

    // MARK: - System Monitor

    /// One-shot CPU / memory / battery / network snapshot.
    public func systemMonitor() async -> HeadlessMonitorReport {
        await runSystemMonitorOnMain()
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
    // Reflect brew's real exit status rather than hardcoding success; a failed
    // `brew upgrade` must surface as upgraded:false (and a nonzero CLI exit).
    return HeadlessHomebrewUpgradeResult(
        upgraded: service.lastUpgradeSucceeded ?? false,
        log: service.upgradeLog,
        remainingOutdated: remaining
    )
}

@MainActor
private func runHomebrewCleanupOnMain() async throws -> HeadlessHomebrewCleanupResult {
    let service = HomebrewService()
    guard service.brewExists() else {
        throw HeadlessServiceError.homebrewNotInstalled
    }
    let result = await service.cleanup()
    return HeadlessHomebrewCleanupResult(
        success: result.success,
        reclaimedText: result.reclaimedText,
        log: result.log
    )
}

@MainActor
private func runHomebrewLeavesOnMain() async throws -> HeadlessHomebrewLeavesReport {
    let service = HomebrewService()
    guard service.brewExists() else {
        throw HeadlessServiceError.homebrewNotInstalled
    }
    let leaves = await service.leaves()
    return HeadlessHomebrewLeavesReport(count: leaves.count, leaves: leaves)
}

@MainActor
private func runSelfUpdateOnMain(apply: Bool) async throws -> HeadlessSelfUpdateResult {
    let command = HomebrewService.selfUpgradeCommand
    let current = MacSweepVersion.current
    // Default (no --yes): just report the command; never require brew to be present.
    guard apply else {
        return HeadlessSelfUpdateResult(
            currentVersion: current,
            upgradeCommand: command,
            applied: false,
            log: nil
        )
    }
    let service = HomebrewService()
    guard service.brewExists() else {
        throw HeadlessServiceError.homebrewNotInstalled
    }
    let result = await service.selfUpgrade()
    return HeadlessSelfUpdateResult(
        currentVersion: current,
        upgradeCommand: command,
        applied: result.success,
        log: result.log
    )
}

// MARK: - Process bridges
//
// ProcessMonitor is a @MainActor ObservableObject and RunningProcess carries a
// non-Sendable NSImage icon. These bridges run on the main actor and return ONLY
// the Sendable Headless* projections.

@MainActor
private func runProcessListOnMain(sort: String) async -> HeadlessProcessReport {
    let monitor = ProcessMonitor()
    await monitor.refresh()
    var procs = monitor.processes
    let order: String
    switch sort.lowercased() {
    case "cpu":
        procs.sort { $0.cpuPercent > $1.cpuPercent }
        order = "cpu"
    case "name":
        procs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        order = "name"
    default:
        procs.sort { $0.memoryMB > $1.memoryMB }
        order = "memory"
    }
    let mapped = procs.map { proc in
        HeadlessProcess(
            pid: Int32(proc.pid),
            name: proc.name,
            bundleID: proc.bundleID,
            memoryMB: proc.memoryMB,
            cpuPercent: proc.cpuPercent,
            isActive: proc.isActive
        )
    }
    return HeadlessProcessReport(sortOrder: order, totalProcesses: mapped.count, processes: mapped)
}

@MainActor
private func runProcessQuitOnMain(target: String, force: Bool) async throws -> HeadlessProcessQuitResult {
    let monitor = ProcessMonitor()
    await monitor.refresh()
    let processes = monitor.processes

    // Resolve target: explicit PID first, then case-insensitive name substring.
    let resolved: RunningProcess
    if let pidValue = Int32(target), let match = processes.first(where: { $0.pid == pidValue }) {
        resolved = match
    } else {
        let nameMatches = processes.filter {
            $0.name.range(of: target, options: .caseInsensitive) != nil
        }
        if nameMatches.isEmpty {
            throw HeadlessServiceError.processNotFound(target)
        }
        if nameMatches.count > 1 {
            let labels = nameMatches.map { "\($0.name) (pid \($0.pid))" }
            throw HeadlessServiceError.processAmbiguous(target, labels)
        }
        resolved = nameMatches[0]
    }

    let pid = resolved.pid
    // Never signal init (pid 1) or our own process.
    guard pid > 1, pid != getpid() else {
        throw HeadlessServiceError.processQuitRefused("\(resolved.name) (pid \(pid))")
    }

    let terminated: Bool
    if force {
        terminated = kill(pid, SIGKILL) == 0
    } else if let app = NSRunningApplication(processIdentifier: pid) {
        terminated = app.terminate()
    } else {
        terminated = kill(pid, SIGTERM) == 0
    }

    return HeadlessProcessQuitResult(
        pid: Int32(pid),
        name: resolved.name,
        forced: force,
        terminated: terminated
    )
}

// MARK: - Privacy bridge

@MainActor
private func runPrivacyActionOnMain(action: String) async throws -> HeadlessPrivacyActionResult {
    switch action.lowercased() {
    case "clear-clipboard":
        PrivacyActions.clearClipboard()
        return HeadlessPrivacyActionResult(
            action: "clear-clipboard",
            success: true,
            message: "Clipboard cleared."
        )
    case "clear-terminal-history":
        try await PrivacyActions.clearTerminalHistory()
        return HeadlessPrivacyActionResult(
            action: "clear-terminal-history",
            success: true,
            message: "Shell history files moved to Trash."
        )
    case "clear-recent-docs":
        try await PrivacyActions.clearRecentDocuments()
        return HeadlessPrivacyActionResult(
            action: "clear-recent-docs",
            success: true,
            message: "Recent documents list cleared."
        )
    default:
        throw HeadlessServiceError.unknownPrivacyAction(action)
    }
}

// MARK: - System monitor bridge

@MainActor
private func runSystemMonitorOnMain() async -> HeadlessMonitorReport {
    let monitor = SystemMonitor()
    // init() starts a 2s polling timer; stop it for a one-shot read.
    monitor.stopMonitoring()

    let cpu = await monitor.fetchCPUUsage()
    let mem = await monitor.fetchMemoryUsage()
    let bat = await monitor.fetchBatteryInfo()

    // Network speed is a delta between two samples: prime, wait ~1s, re-read.
    _ = await monitor.fetchNetworkUsage()
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    let net = await monitor.fetchNetworkUsage()

    let cpuReport = HeadlessCPUReport(
        userPercent: cpu.user,
        systemPercent: cpu.system,
        idlePercent: cpu.idle,
        totalPercent: cpu.total,
        temperatureCelsius: cpu.temperature
    )
    let memReport = HeadlessMemoryReport(
        totalBytes: mem.total,
        usedBytes: mem.used,
        freeBytes: mem.free,
        wiredBytes: mem.wired,
        activeBytes: mem.active,
        inactiveBytes: mem.inactive,
        compressedBytes: mem.compressed,
        availableBytes: mem.available,
        usedPercentage: mem.usedPercentage * 100,
        pressureLevel: mem.pressureLevel.rawValue
    )
    let batReport = HeadlessBatteryReport(
        hasBattery: bat.hasBattery,
        percentage: bat.percentage,
        isCharging: bat.isCharging,
        isPluggedIn: bat.isPluggedIn,
        timeRemainingMinutes: bat.timeRemaining,
        cycleCount: bat.cycleCount,
        healthPercent: bat.health,
        statusText: bat.statusText
    )
    let netReport = HeadlessNetworkReport(
        downloadSpeedBytesPerSec: net.downloadSpeed,
        uploadSpeedBytesPerSec: net.uploadSpeed,
        totalDownloadedBytes: net.totalDownloaded,
        totalUploadedBytes: net.totalUploaded,
        isConnected: net.isConnected,
        interfaceName: net.interfaceName,
        ssid: net.ssid
    )
    let devices = await ConnectedDeviceScanner.scan().map { device in
        HeadlessConnectedDevice(
            name: device.name,
            type: device.typeLabel,
            battery: device.battery,
            batteryLeft: device.batteryLeft,
            batteryRight: device.batteryRight,
            batteryCase: device.batteryCase
        )
    }
    return HeadlessMonitorReport(
        chipName: monitor.chipName,
        cpu: cpuReport,
        memory: memReport,
        battery: batReport,
        network: netReport,
        connectedDevices: devices
    )
}
