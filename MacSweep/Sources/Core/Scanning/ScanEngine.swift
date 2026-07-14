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
            let formatted = size.formattedFileSize
            return "This will delete \(formatted), which needs confirmation before proceeding."
        }
    }
}

/// A single module that failed during a scan, captured rather than swallowed.
struct ModuleScanFailure: Sendable, Equatable {
    let moduleID: String
    let moduleName: String
    let message: String

    /// Permission failures need a different recovery path from transient scan
    /// failures. Keep the classifier in core so every UI presents the same
    /// diagnosis instead of relying on view-specific string checks.
    var requiresFullDiskAccess: Bool {
        let normalized = message.lowercased()
        if normalized.contains("full disk access") {
            return true
        }

        let fullDiskAccessModules = ["browser-safari", "mail-attachments", "privacy"]
        guard fullDiskAccessModules.contains(moduleID) else { return false }

        return [
            "operation not permitted",
            "permission denied",
            "access denied",
            "not authorized"
        ].contains { normalized.contains($0) }
    }

    /// A single-line reason suitable for an inline banner. The complete message
    /// remains available for copied diagnostic reports.
    var conciseMessage: String {
        let singleLine = message
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = singleLine.isEmpty ? "The module did not return a reason." : singleLine
        guard fallback.count > 160 else { return fallback }
        return String(fallback.prefix(157)) + "…"
    }
}

/// Result of a scan that records which modules failed instead of silently
/// returning a short item list. A partial scan (some modules failed) is still a
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
    private struct PartialCleanupFailure: Error {
        let finalizedItems: [CleanupItem]
        let partialResult: CleanupResult
        let remainingItems: [CleanupItem]
        let underlyingError: Error
    }

    private struct CleanupProgress {
        var processedCount = 0
        var bytesFreed: Int64 = 0
        var errors: [CleanupError] = []
        var historyActions: [CleanupItem.ID: CleanupHistoryAction] = [:]
        var finalizedItems: [CleanupItem] = []
        var finalizedItemIDs = Set<CleanupItem.ID>()

        var result: CleanupResult {
            CleanupResult(
                itemsProcessed: processedCount,
                bytesFreed: bytesFreed,
                errors: errors,
                historyActions: historyActions
            )
        }

        mutating func finalize(_ items: [CleanupItem], result: CleanupResult? = nil) {
            if let result {
                let (nextProcessedCount, countOverflow) = processedCount.addingReportingOverflow(
                    result.itemsProcessed
                )
                processedCount = countOverflow ? Int.max : nextProcessedCount
                let (nextBytesFreed, bytesOverflow) = bytesFreed.addingReportingOverflow(
                    result.bytesFreed
                )
                bytesFreed = bytesOverflow ? Int64.max : nextBytesFreed
                errors.append(contentsOf: result.errors)
                historyActions.merge(result.historyActions) { _, action in action }
            }
            finalizedItems.append(contentsOf: items)
            finalizedItemIDs.formUnion(items.map(\.id))
        }
    }

    private var modules: [any ScanModule] = []
    private let safetyChecker = SafetyChecker()
    private let deletionGuard: DeletionGuard
    private let cleanupHistoryStore: CleanupHistoryStore
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

    init(
        modules: [any ScanModule]? = nil,
        // Default to the user-configured cap (Settings → Safety) so every
        // feature that constructs a fresh engine picks the setting up.
        deletionGuard: DeletionGuard = .fromPreferences(),
        cleanupHistoryStore: CleanupHistoryStore = .shared
    ) {
        self.modules = modules ?? Self.defaultModules()
        self.deletionGuard = deletionGuard
        self.cleanupHistoryStore = cleanupHistoryStore
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

        return items.compactMap { item in
            guard safetyChecker.validateForScan(item, moduleID: module.id).isSafe else {
                return nil
            }
            let cleanup = safetyChecker.validateForCleanup(item, moduleID: module.id)
            return item.markingCleanupReview(reason: cleanup.reason)
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
    /// surface that the result is partial. Cancellation is excluded because a
    /// user stopping a scan is not a module failure.
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
            case cancelled(moduleID: String, moduleName: String)
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
                        let safe: [CleanupItem] = items.compactMap { item in
                            guard self.safetyChecker.validateForScan(item, moduleID: module.id).isSafe else {
                                return nil
                            }
                            let cleanup = self.safetyChecker.validateForCleanup(item, moduleID: module.id)
                            return item.markingCleanupReview(reason: cleanup.reason)
                        }
                        return .items(moduleID: module.id, moduleName: module.name, items: safe)
                    } catch is CancellationError {
                        return .cancelled(moduleID: module.id, moduleName: module.name)
                    } catch {
                        return .failure(ModuleScanFailure(
                            moduleID: module.id,
                            moduleName: module.name,
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
                case .cancelled(let moduleID, let moduleName):
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
        if dryRun {
            return try await performClean(
                items: items,
                dryRun: true,
                confirmedLargeDeletion: confirmedLargeDeletion
            )
        }

        do {
            let result = try await performClean(
                items: items,
                dryRun: false,
                confirmedLargeDeletion: confirmedLargeDeletion
            )
            cleanupHistoryStore.record(items: items, result: result)
            return result
        } catch let partial as PartialCleanupFailure {
            if !partial.finalizedItems.isEmpty {
                cleanupHistoryStore.record(
                    items: partial.finalizedItems,
                    result: partial.partialResult
                )
            }
            if !partial.remainingItems.isEmpty {
                cleanupHistoryStore.recordFailure(
                    items: partial.remainingItems,
                    error: partial.underlyingError
                )
            }
            throw partial.underlyingError
        } catch {
            cleanupHistoryStore.recordFailure(items: items, error: error)
            throw error
        }
    }

    private func performClean(
        items: [CleanupItem],
        dryRun: Bool,
        confirmedLargeDeletion: Bool
    ) async throws -> CleanupResult {
        var progress = CleanupProgress()
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
                progress.errors.append(contentsOf: moduleItems.map {
                    CleanupError(path: $0.path, message: "No cleanup module registered for \(moduleID)")
                })
                progress.finalize(moduleItems)
                continue
            }

            let safeItems = moduleItems.filter { item in
                let validation = safetyChecker.validateForCleanup(item, moduleID: moduleID)

                if !validation.isSafe {
                    progress.errors.append(CleanupError(
                        path: item.path,
                        message: "Safety check failed: \(validation.reason ?? "protected")"
                    ))
                    progress.finalize([item])
                }

                return validation.isSafe
            }

            guard !safeItems.isEmpty else { continue }
            plan.append((module, safeItems))
        }

        // Deletion guard: the last operation before destructive module dispatch.
        // It remeasures every selected filesystem path now (including hidden
        // descendants, without following final-component symlinks), deduplicates
        // overlaps, and fails closed on incomplete/overflowing measurement. A dry
        // run touches nothing, so previews remain exempt. Both the hard cap and
        // confirmation threshold use this live total.
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

        // Second pass: execute cleanup in priority order. Remeasure each module's
        // targets immediately before dispatch because an earlier module (or an
        // external process) can change a later target after the aggregate gate.
        // Carry forward the measured impact of earlier dispatches so the 10 GiB
        // cap applies to the whole operation, even when modules return incomplete
        // or stale bytes-freed accounting.
        try await executeCleanupPlan(
            plan,
            allItems: items,
            dryRun: dryRun,
            confirmedLargeDeletion: confirmedLargeDeletion,
            progress: &progress
        )
        return progress.result
    }

    private func executeCleanupPlan(
        _ plan: [(module: any ScanModule, items: [CleanupItem])],
        allItems: [CleanupItem],
        dryRun: Bool,
        confirmedLargeDeletion: Bool,
        progress: inout CleanupProgress
    ) async throws {
        var authorizedImpact: Int64 = 0
        for entry in plan {
            do {
                if !dryRun {
                    authorizedImpact = try evaluateAuthorizedImpact(
                        for: entry.items,
                        alreadyAuthorized: authorizedImpact,
                        confirmedLargeDeletion: confirmedLargeDeletion
                    )
                }
                let result = try await entry.module.clean(items: entry.items, dryRun: dryRun)
                progress.finalize(entry.items, result: result)
            } catch {
                guard !dryRun else { throw error }
                throw partialCleanupFailure(
                    progress: progress,
                    allItems: allItems,
                    underlyingError: error
                )
            }
        }
    }

    private func evaluateAuthorizedImpact(
        for items: [CleanupItem],
        alreadyAuthorized: Int64,
        confirmedLargeDeletion: Bool
    ) throws -> Int64 {
        switch deletionGuard.evaluate(items: items, alreadyAuthorizedSize: alreadyAuthorized) {
        case .blocked(let reason):
            throw ScanEngineError.deletionBlocked(reason: reason)
        case .requiresConfirmation(let cumulativeSize):
            guard confirmedLargeDeletion else {
                throw ScanEngineError.confirmationRequired(size: cumulativeSize)
            }
            return cumulativeSize
        case .allowed(let cumulativeSize):
            return cumulativeSize
        }
    }

    private func partialCleanupFailure(
        progress: CleanupProgress,
        allItems: [CleanupItem],
        underlyingError: Error
    ) -> PartialCleanupFailure {
        PartialCleanupFailure(
            finalizedItems: progress.finalizedItems,
            partialResult: progress.result,
            remainingItems: allItems.filter { !progress.finalizedItemIDs.contains($0.id) },
            underlyingError: underlyingError
        )
    }
}
