import Foundation

/// Orchestrates scanning across all modules
/// Errors raised by the scan/clean orchestration layer.
enum ScanEngineError: Error, LocalizedError, Equatable {
    /// The aggregate deletion size exceeded the hard guard limit.
    case deletionBlocked(reason: String)

    /// The aggregate deletion size crossed the confirmation threshold and the
    /// caller has not confirmed. Callers behind a user confirmation (GUI dialog,
    /// CLI `--yes`) pass `confirmedLargeDeletion: true` to proceed.
    case confirmationRequired(size: Int64)

    var errorDescription: String? {
        switch self {
        case .deletionBlocked(let reason):
            return reason
        case .confirmationRequired(let size):
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return "This will delete \(formatted), which needs confirmation before proceeding."
        }
    }
}

/// A single module that failed during a scan, captured rather than swallowed.
struct ModuleScanFailure: Sendable, Equatable {
    let moduleID: String
    let message: String
}

/// Result of a scan that records which modules failed instead of silently
/// returning a short item list. A partial scan (some modules threw) is still a
/// useful result, but the caller must be able to tell the user it was partial.
struct PartialScanResult: Sendable {
    let items: [CleanupItem]
    let failures: [ModuleScanFailure]

    /// True when at least one module failed and its results are missing.
    var isPartial: Bool { !failures.isEmpty }
}

/// A coarse progress update emitted as scan modules finish.
struct ScanProgressUpdate: Sendable, Equatable {
    let completedModules: Int
    let totalModules: Int
    let moduleID: String?
    let moduleName: String?

    var fractionCompleted: Double {
        guard totalModules > 0 else { return 0 }
        return min(1, max(0, Double(completedModules) / Double(totalModules)))
    }
}

typealias ScanProgressHandler = @Sendable (ScanProgressUpdate) async -> Void

actor ScanEngine {
    private var modules: [any ScanModule] = []
    private let safetyChecker = SafetyChecker()
    private let deletionGuard = DeletionGuard()
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
            safetyChecker.validateForScan(item, moduleID: module.id).isSafe
        }
    }

    func smartCareScan(progress: ScanProgressHandler? = nil) async throws -> [CleanupItem] {
        try await scan(modules: SmartCareDefaults.moduleIDs, progress: progress)
    }

    /// Scan all modules or specific ones, returning only the items.
    ///
    /// Back-compat shim over ``scanWithDiagnostics(modules:)``. A module that
    /// throws is dropped from the results; callers that need to know a scan was
    /// partial (to warn the user) should use ``scanWithDiagnostics(modules:)``.
    /// Retains `throws` purely so existing `try await` call sites stay valid;
    /// the body itself never throws.
    func scan(modules moduleIDs: [String]? = nil, progress: ScanProgressHandler? = nil) async throws -> [CleanupItem] {
        await scanWithDiagnostics(modules: moduleIDs, progress: progress).items
    }

    /// Scan all modules or specific ones, capturing per-module failures.
    ///
    /// Unlike ``scan(modules:)``, a thrown module error is recorded as a
    /// ``ModuleScanFailure`` rather than silently swallowed, so the caller can
    /// surface that the result is partial.
    func scanWithDiagnostics(modules moduleIDs: [String]? = nil, progress: ScanProgressHandler? = nil) async -> PartialScanResult {
        let modulesToScan: [any ScanModule]

        if let ids = moduleIDs {
            modulesToScan = modules.filter { ids.contains($0.id) }
        } else {
            modulesToScan = modules
        }

        // Each task returns either the module's safe items or a captured failure;
        // a failing module never tears down the whole group.
        enum ModuleOutcome: Sendable {
            case items(moduleID: String, moduleName: String, items: [CleanupItem])
            case failure(ModuleScanFailure, moduleName: String)
        }

        let totalModules = modulesToScan.count
        await progress?(ScanProgressUpdate(
            completedModules: 0,
            totalModules: totalModules,
            moduleID: nil,
            moduleName: nil
        ))

        return await withTaskGroup(of: ModuleOutcome.self) { group in
            for module in modulesToScan {
                group.addTask {
                    do {
                        let items = try await module.scan()
                        // Filter through safety checker
                        let safe = items.filter { item in
                            self.safetyChecker.validateForScan(item, moduleID: module.id).isSafe
                        }
                        return .items(moduleID: module.id, moduleName: module.name, items: safe)
                    } catch {
                        return .failure(ModuleScanFailure(
                            moduleID: module.id,
                            message: error.localizedDescription
                        ), moduleName: module.name)
                    }
                }
            }

            var allItems: [CleanupItem] = []
            var failures: [ModuleScanFailure] = []
            var completedModules = 0
            for await outcome in group {
                completedModules += 1

                switch outcome {
                case .items(let moduleID, let moduleName, let items):
                    allItems.append(contentsOf: items)
                    await progress?(ScanProgressUpdate(
                        completedModules: completedModules,
                        totalModules: totalModules,
                        moduleID: moduleID,
                        moduleName: moduleName
                    ))
                case .failure(let failure, let moduleName):
                    failures.append(failure)
                    await progress?(ScanProgressUpdate(
                        completedModules: completedModules,
                        totalModules: totalModules,
                        moduleID: failure.moduleID,
                        moduleName: moduleName
                    ))
                }
            }
            return PartialScanResult(items: allItems, failures: failures)
        }
    }

    /// Clean specified items.
    ///
    /// `confirmedLargeDeletion` records that a user has already confirmed a
    /// large deletion (via a GUI dialog or CLI `--yes`). When the aggregate size
    /// crosses `DeletionGuard.confirmationThreshold` and this is `false`, the
    /// clean is refused with `.confirmationRequired` — the threshold is a live
    /// gate, not advisory. Defaults to `false` so any caller that forgets to
    /// confirm fails closed rather than silently deleting.
    func clean(items: [CleanupItem], dryRun: Bool, confirmedLargeDeletion: Bool = false) async throws -> CleanupResult {
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

        // First pass: resolve modules and filter each group through the safety
        // checker, recording per-item safety failures. Nothing is deleted yet so
        // the deletion guard can veto the whole operation below.
        var plan: [(module: any ScanModule, items: [CleanupItem])] = []
        for moduleID in orderedModuleIDs {
            guard let moduleItems = groupedItems[moduleID] else { continue }
            guard let module = modulesByID[moduleID] else {
                errors.append(contentsOf: moduleItems.map {
                    CleanupError(path: $0.path, message: "No cleanup module registered for \(moduleID)")
                })
                continue
            }

            let safeItems = moduleItems.filter { item in
                let validation = safetyChecker.validateForCleanup(item, moduleID: moduleID)

                if !validation.isSafe {
                    errors.append(CleanupError(
                        path: item.path,
                        message: "Safety check failed: \(validation.reason ?? "protected")"
                    ))
                }

                return validation.isSafe
            }

            guard !safeItems.isEmpty else { continue }
            plan.append((module, safeItems))
        }

        // Deletion guard: a hard backstop against runaway deletes. Enforced only
        // for real deletions — a dry run touches nothing, so previews of any size
        // are always permitted. Both the hard cap (.blocked) and the confirmation
        // threshold (.requiresConfirmation) are enforced here; the latter demands
        // the caller pass `confirmedLargeDeletion` (a GUI dialog or CLI --yes).
        if !dryRun {
            let aggregate = plan.flatMap { $0.items }
            switch deletionGuard.preflightCheck(items: aggregate) {
            case .blocked(let reason):
                throw ScanEngineError.deletionBlocked(reason: reason)
            case .requiresConfirmation(let size):
                if !confirmedLargeDeletion {
                    throw ScanEngineError.confirmationRequired(size: size)
                }
            case .allowed:
                break
            }
        }

        // Second pass: execute cleanup in priority order.
        for entry in plan {
            let result = try await entry.module.clean(items: entry.items, dryRun: dryRun)
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
