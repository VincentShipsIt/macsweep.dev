import Foundation

/// Orchestrates scanning across all modules
actor ScanEngine {
    private var modules: [any ScanModule] = []
    private let safetyChecker = SafetyChecker()
    private static let cleanupPriority: [String] = [
        "trash-bins",
        "system-cache",
        "cloud-cleanup",
        "mail-attachments",
        "dev-tools",
        "package-managers",
        "docker",
        "network",
        "duplicates",
        "similar-photos",
        "large-files",
        "privacy",
        "browser-safari",
        "browser-chrome",
        "browser-firefox",
        "browser-brave",
        "browser-arc",
        "service-workers",
    ]

    init(modules: [any ScanModule]? = nil) {
        self.modules = modules ?? Self.defaultModules()
    }

    private static func defaultModules() -> [any ScanModule] {
        [
            // Cleanup
            SystemCacheModule(),
            DuplicateFinderModule(),
            SimilarPhotosModule(),
            CloudCleanupModule(),
            AssistantWatchlistModule(),

            // Browsers
            ChromeModule(),
            SafariModule(),
            FirefoxModule(),
            BraveModule(),
            ArcModule(),
            ServiceWorkerModule(),

            // Files
            LargeFilesModule(),
            DevToolsModule(),

            // Cleanup
            TrashBinsModule(),
            MailAttachmentsModule(),
            PrivacyModule(),

            // Developer
            PackageManagerModule(),
            DockerModule(),
            NetworkModule(),
        ]
    }

    /// Register a custom module
    func register(_ module: any ScanModule) {
        modules.append(module)
    }

    /// Get all registered modules
    func registeredModules() -> [any ScanModule] {
        modules
    }

    func scanAssistantTargets(_ targets: [AssistantScanTarget]) async throws -> [CleanupItem] {
        guard !targets.isEmpty else { return [] }

        let module = AssistantWatchlistModule(targets: targets)
        let items = try await module.scan()

        return items.filter { item in
            safetyChecker.validateForScan(item.path, moduleID: item.module).isSafe
        }
    }

    func smartCareScan() async throws -> [CleanupItem] {
        try await scan(modules: SmartCareDefaults.moduleIDs)
    }

    /// Scan all modules or specific ones
    func scan(modules moduleIDs: [String]? = nil) async throws -> [CleanupItem] {
        let modulesToScan: [any ScanModule]

        if let ids = moduleIDs {
            modulesToScan = modules.filter { ids.contains($0.id) }
        } else {
            modulesToScan = modules
        }

        // Parallel scanning
        return try await withThrowingTaskGroup(of: [CleanupItem].self) { group in
            for module in modulesToScan {
                group.addTask {
                    do {
                        let items = try await module.scan()
                        // Filter through safety checker
                        return items.filter { item in
                            self.safetyChecker.validateForScan(item.path, moduleID: item.module).isSafe
                        }
                    } catch {
                        print("Module \(module.id) scan failed: \(error)")
                        return []
                    }
                }
            }

            var allItems: [CleanupItem] = []
            for try await items in group {
                allItems.append(contentsOf: items)
            }
            return allItems
        }
    }

    /// Clean specified items
    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processedCount = 0
        var bytesFreed: Int64 = 0
        var errors: [CleanupError] = []
        let groupedItems = Dictionary(grouping: items, by: \.module)
        let modulesByID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
        let orderedModuleIDs = groupedItems.keys.sorted { lhs, rhs in
            let lhsPriority = Self.cleanupPriority.firstIndex(of: lhs) ?? .max
            let rhsPriority = Self.cleanupPriority.firstIndex(of: rhs) ?? .max

            if lhsPriority == rhsPriority {
                return lhs < rhs
            }

            return lhsPriority < rhsPriority
        }

        for moduleID in orderedModuleIDs {
            guard let moduleItems = groupedItems[moduleID] else { continue }
            guard let module = modulesByID[moduleID] else {
                errors.append(contentsOf: moduleItems.map {
                    CleanupError(path: $0.path, message: "No cleanup module registered for \(moduleID)")
                })
                continue
            }

            let safeItems = moduleItems.filter { item in
                let validation = safetyChecker.validateForCleanup(
                    item.path,
                    moduleID: item.module,
                    itemType: item.type
                )

                if !validation.isSafe {
                    errors.append(CleanupError(
                        path: item.path,
                        message: "Safety check failed: \(validation.reason ?? "protected")"
                    ))
                }

                return validation.isSafe
            }

            guard !safeItems.isEmpty else { continue }

            let result = try await module.clean(items: safeItems, dryRun: dryRun)
            processedCount += result.itemsProcessed
            bytesFreed += result.bytesFreed
            errors.append(contentsOf: result.errors)
        }

        return CleanupResult(
            itemsProcessed: processedCount,
            bytesFreed: bytesFreed,
            errors: errors
        )
    }
}
