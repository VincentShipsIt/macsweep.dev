import Combine
import Foundation

/// Global application state
@MainActor
final class AppState: ObservableObject {
    // MARK: - Scanning State
    @Published var isScanning = false
    @Published var scanProgress: Double = 0
    @Published var currentScanModule: String?
    @Published var scanResults: [CleanupItem] = []
    @Published var selectedItems: Set<CleanupItem.ID> = []
    @Published var smartCareSummary: SmartCareSummary?
    @Published var scanFailures: [ModuleScanFailure] = []

    /// Last scan failure, surfaced to the UI. Cleared at the start of each scan.
    @Published var lastError: String?

    /// Last deletion failure (cap hit, safety block, or per-item error), surfaced
    /// to the UI separately from scan errors. Cleared at the start of each cleanup.
    @Published var lastDeletionError: String?

    // MARK: - Disk Usage
    @Published var diskUsage: DiskUsage?

    // MARK: - Last Cleanup
    @Published var lastCleanup: CleanupResult?
    @Published var cleanupPerformanceHistory: [CleanupPerformanceEntry] = []

    // MARK: - UI State
    @Published var selectedFeature: Feature = .smartScan
    @Published var showingConfirmation = false
    @Published private(set) var hasFullDiskAccess: Bool

    // MARK: - Menu Bar
    var menuBarIcon: String {
        if isScanning {
            return "sparkles"
        } else if let usage = diskUsage, usage.freePercentage < 0.1 {
            return "exclamationmark.triangle.fill"
        } else {
            return "sparkles.rectangle.stack"
        }
    }

    // MARK: - Engines
    let scanEngine: ScanEngine
    let safetyChecker = SafetyChecker()
    let assistant: AssistantCoordinator
    /// One process sampler shared by Dashboard, Optimization, and menu-bar detail
    /// panels so concurrent surfaces don't each spawn a 5s `ps` loop.
    let processMonitor = ProcessMonitor()
    /// One system-metrics monitor for dashboard, menu bar, optimization, and
    /// battery views so they don't each run independent 2s / 30s probe timers.
    let systemMonitor = SystemMonitor()
    private let cleanupPerformanceStore: CleanupPerformanceStore
    private let diskUsageProvider: @Sendable () async -> DiskUsage?
    private let cleanupOperation: (([CleanupItem], Bool, Bool) async throws -> CleanupResult)?
    var activeScanTask: Task<Void, Never>?
    var activeScanID: UUID?
    var lastScanScope: ScanScope?

    struct ScanScope {
        let modules: [String]?
        let assistantTargets: [AssistantScanTarget]
        let requiresFullDiskAccess: Bool
    }

    // MARK: - Initialization
    init(
        initialFullDiskAccess: Bool = FullDiskAccess.hasAccess,
        scanEngine: ScanEngine = ScanEngine(),
        assistant: AssistantCoordinator? = nil,
        cleanupPerformanceStore: CleanupPerformanceStore = .shared,
        diskUsageProvider: @escaping @Sendable () async -> DiskUsage? = { await DiskUsage.current() },
        cleanupOperation: (([CleanupItem], Bool, Bool) async throws -> CleanupResult)? = nil
    ) {
        hasFullDiskAccess = initialFullDiskAccess
        self.scanEngine = scanEngine
        self.assistant = assistant ?? AssistantCoordinator()
        self.cleanupPerformanceStore = cleanupPerformanceStore
        self.diskUsageProvider = diskUsageProvider
        self.cleanupOperation = cleanupOperation
        cleanupPerformanceHistory = cleanupPerformanceStore.history

        Task {
            await refreshDiskUsage()
        }
    }

    // MARK: - Actions

    /// Stop the in-flight scan, if any. The scan modules check
    /// `Task.checkCancellation()` inside their enumeration loops, so this
    /// actually halts the disk walk instead of letting it run to completion.
    /// A queued caller waiting in `startScan` proceeds normally afterwards.
    func cancelScan() {
        activeScanTask?.cancel()
    }

    func quickScan() async {
        guard hasFullDiskAccess else {
            lastError = FullDiskAccessScope.smartCare.actionBlockedMessage
            return
        }

        await startScan(
            scope: ScanScope(
                modules: SmartCareDefaults.moduleIDs,
                assistantTargets: assistant.enabledTargets, requiresFullDiskAccess: true
            ))
    }

    func scan(modules: [String]? = nil) async {
        if modules == nil, !hasFullDiskAccess {
            lastError = FullDiskAccessScope.smartCare.actionBlockedMessage
            return
        }

        await startScan(
            scope: ScanScope(
                modules: modules,
                assistantTargets: modules == nil ? assistant.enabledTargets : [], requiresFullDiskAccess: modules == nil
            ))
    }

    func retryLastScan() async {
        guard let lastScanScope else {
            await quickScan()
            return
        }
        guard !lastScanScope.requiresFullDiskAccess || hasFullDiskAccess else {
            lastError = FullDiskAccessScope.smartCare.actionBlockedMessage
            return
        }
        await startScan(scope: lastScanScope)
    }

    func deleteSelected(dryRun: Bool = false, confirmedLargeDeletion: Bool = false) async throws -> CleanupResult {
        if !dryRun { lastDeletionError = nil }
        let itemsToDelete = scanResults.filter { selectedItems.contains($0.id) }
        let submittedIDs = Set(itemsToDelete.map(\.id))
        // Re-read the current max-delete-size preference for every cleanup.
        let engine = ScanEngine()

        let result: CleanupResult
        do {
            if let cleanupOperation {
                result = try await cleanupOperation(itemsToDelete, dryRun, confirmedLargeDeletion)
            } else {
                result = try await engine.clean(
                    items: itemsToDelete, dryRun: dryRun,
                    confirmedLargeDeletion: confirmedLargeDeletion)
            }
        } catch {
            // Surface the failure (e.g. the DeletionGuard cap) so callers using
            // `try?` still give the user feedback instead of swallowing it.
            if !dryRun { lastDeletionError = error.localizedDescription }
            throw error
        }

        if !dryRun {
            lastCleanup = result
            recordCleanupPerformance(result)
            // Per-item failures are returned in result.errors (not thrown). Only
            // remove items that actually left disk; keep failed ones in the list
            // rather than silently dropping them.
            scanResults.removeAll { submittedIDs.contains($0.id) && result.errors.failure(affecting: $0) == nil }
            selectedItems.formIntersection(Set(scanResults.map(\.id)))
            smartCareSummary =
                scanResults.isEmpty
                ? nil
                : SmartCareAnalyzer().summarize(items: scanResults, diskUsage: diskUsage)
            await refreshDiskUsage()
            if let summary = result.failureSummaryMessage {
                lastDeletionError = summary
            }
        }

        return result
    }

    func refreshDiskUsage() async {
        diskUsage = await diskUsageProvider()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.hasAccess
    }

    func selectAll() {
        selectedItems = Set(scanResults.map(\.id))
    }

    func selectRecommended() {
        selectedItems = smartCareSummary?.recommendedCleanupItemIDs ?? []
    }

    func deselectAll() {
        selectedItems.removeAll()
    }

    func recordCleanupPerformance(_ result: CleanupResult) {
        cleanupPerformanceStore.record(result)
        cleanupPerformanceHistory = cleanupPerformanceStore.history
    }

    func selectItems(withIDs ids: Set<CleanupItem.ID>) {
        selectedItems.formUnion(ids)
    }

    func deselectItems(withIDs ids: Set<CleanupItem.ID>) {
        selectedItems.subtract(ids)
    }

    func toggleSelection(for item: CleanupItem) {
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
    }

    var selectedSize: Int64 {
        scanResults.totalSize(selected: selectedItems)
    }

    func feature(for moduleID: String) -> Feature? {
        Self.moduleFeatures[moduleID]

    }

    private static let moduleFeatures: [String: Feature] = [
        AssistantWatchlistModule.moduleID: .assistant,
        "system-cache": .systemJunk, "mail-attachments": .mailAttachments, "trash-bins": .trashBins,
        "dev-tools": .devTools, "package-managers": .devTools, "developer-cli-logs": .devTools,
        "docker": .devTools, "network": .networkCleanup, "privacy": .privacy,
        "browser-chrome": .privacy, "browser-safari": .privacy, "browser-firefox": .privacy,
        "browser-brave": .privacy, "browser-arc": .privacy, "service-workers": .privacy,
        "large-files": .largeOldFiles, "duplicates": .duplicateFiles, "similar-photos": .similarPhotos,
        "cloud-cleanup": .cloudCleanup
    ]

    func runAssistantPlan(_ plan: AssistantScanPlan) async {
        await startScan(
            scope: ScanScope(
                modules: plan.modules,
                assistantTargets: plan.customTargets, requiresFullDiskAccess: false
            ))
    }

}
