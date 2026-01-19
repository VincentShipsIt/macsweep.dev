import Foundation

/// Orchestrates scanning across all modules
actor ScanEngine {
    private var modules: [any ScanModule] = []
    private let safetyChecker = SafetyChecker()

    init() {
        // Modules are registered inline
        modules = [
            // Cleanup
            SystemCacheModule(),
            DuplicateFinderModule(),

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
                            self.safetyChecker.validate(item.path).isSafe
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

        for item in items {
            // Double-check safety
            let validation = safetyChecker.validate(item.path)
            guard validation.isSafe else {
                errors.append(CleanupError(
                    path: item.path,
                    message: "Safety check failed: \(validation.reason ?? "protected")"
                ))
                continue
            }

            if dryRun {
                processedCount += 1
                bytesFreed += item.size
            } else {
                do {
                    try FileManager.default.removeItem(at: item.path)
                    processedCount += 1
                    bytesFreed += item.size
                } catch {
                    errors.append(CleanupError(
                        path: item.path,
                        message: "Failed to delete",
                        underlyingError: error
                    ))
                }
            }
        }

        return CleanupResult(
            itemsProcessed: processedCount,
            bytesFreed: bytesFreed,
            errors: errors
        )
    }
}
