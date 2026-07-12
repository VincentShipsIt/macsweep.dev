import SwiftUI
import Combine

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
    let scanEngine = ScanEngine()
    let safetyChecker = SafetyChecker()
    let assistant = AssistantCoordinator()
    private let cleanupPerformanceStore = CleanupPerformanceStore.shared
    private var activeScanTask: Task<Void, Never>?
    private var activeScanID: UUID?

    // MARK: - Initialization
    init() {
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
        await startScan(
            moduleScan: { progress in
                await self.scanEngine.scanWithDiagnostics(
                    modules: SmartCareDefaults.moduleIDs,
                    progress: progress
                )
            },
            modules: SmartCareDefaults.moduleIDs,
            assistantTargets: assistant.enabledTargets
        )
    }

    func scan(modules: [String]? = nil) async {
        await startScan(
            moduleScan: { progress in
                await self.scanEngine.scanWithDiagnostics(modules: modules, progress: progress)
            },
            modules: modules,
            assistantTargets: modules == nil ? assistant.enabledTargets : []
        )
    }

    func deleteSelected(dryRun: Bool = false, confirmedLargeDeletion: Bool = false) async throws -> CleanupResult {
        if !dryRun { lastDeletionError = nil }
        let itemsToDelete = scanResults.filter { selectedItems.contains($0.id) }

        let result: CleanupResult
        do {
            result = try await scanEngine.clean(
                items: itemsToDelete,
                dryRun: dryRun,
                confirmedLargeDeletion: confirmedLargeDeletion
            )
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
            let failedPaths = Set(result.errors.map(\.path))
            scanResults.removeAll { selectedItems.contains($0.id) && !failedPaths.contains($0.path) }
            selectedItems = selectedItems.filter { id in scanResults.contains(where: { $0.id == id }) }
            smartCareSummary = scanResults.isEmpty
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
        diskUsage = await DiskUsage.current()
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
        switch moduleID {
        case AssistantWatchlistModule.moduleID: return .assistant
        case "system-cache": return .systemJunk
        case "mail-attachments": return .mailAttachments
        case "trash-bins": return .trashBins
        case "dev-tools", "package-managers", "docker": return .devTools
        case "network": return .networkCleanup
        case "privacy", "browser-chrome", "browser-safari", "browser-firefox", "browser-brave", "browser-arc", "service-workers":
            return .privacy
        case "large-files": return .largeOldFiles
        case "duplicates": return .duplicateFiles
        case "similar-photos": return .similarPhotos
        case "cloud-cleanup": return .cloudCleanup
        default: return nil
        }
    }

    func runAssistantPlan(_ plan: AssistantScanPlan) async {
        await startScan(
            moduleScan: { [scanEngine] progress in
                guard !plan.modules.isEmpty else {
                    return PartialScanResult(items: [], failures: [])
                }
                return await scanEngine.scanWithDiagnostics(modules: plan.modules, progress: progress)
            },
            modules: plan.modules,
            assistantTargets: plan.customTargets
        )
    }

    private func applyScanResults(_ items: [CleanupItem], modules: [String]?) {
        scanResults = items.sorted { $0.size > $1.size }

        let summary = SmartCareAnalyzer().summarize(items: scanResults, diskUsage: diskUsage)
        smartCareSummary = summary

        if modules == nil || Set(modules ?? []).isSuperset(of: SmartCareDefaults.moduleIDs) {
            selectedItems = summary.recommendedCleanupItemIDs
        } else {
            selectedItems = Set(scanResults.map(\.id))
        }
    }

    private func startScan(
        moduleScan: @escaping (ScanProgressHandler?) async -> PartialScanResult,
        modules: [String]?,
        assistantTargets: [AssistantScanTarget]
    ) async {
        // Serialize concurrent scan requests instead of dropping them. The previous
        // early `return` discarded this caller's modules/targets and let them see an
        // unrelated in-flight scan's results (e.g. an assistant plan showing a
        // background quick-scan's findings). Wait for any in-flight scan — and any a
        // peer waiter starts ahead of us — to finish, THEN run the requested scan.
        while let activeScanTask {
            await activeScanTask.value
        }

        let scanID = UUID()
        activeScanID = scanID

        let task = Task { @MainActor in
            await self.performScan(
                moduleScan: moduleScan,
                modules: modules,
                assistantTargets: assistantTargets
            )

            if self.activeScanID == scanID {
                self.activeScanTask = nil
                self.activeScanID = nil
            }
        }

        activeScanTask = task
        await task.value
    }

    private func performScan(
        moduleScan: @escaping (ScanProgressHandler?) async -> PartialScanResult,
        modules: [String]?,
        assistantTargets: [AssistantScanTarget]
    ) async {
        isScanning = true
        scanProgress = 0
        currentScanModule = "Preparing scan"
        scanResults = []
        selectedItems = []
        smartCareSummary = nil
        scanFailures = []
        lastError = nil

        defer {
            isScanning = false
            currentScanModule = nil
        }

        let progressHandler: ScanProgressHandler = { update in
            await MainActor.run {
                self.scanProgress = update.fractionCompleted

                if let moduleName = update.moduleName {
                    self.currentScanModule = "Completed \(moduleName)"
                } else if update.totalModules > 0 {
                    self.currentScanModule = "Scanning \(update.totalModules) modules"
                } else {
                    self.currentScanModule = "Preparing scan"
                }
            }
        }

        do {
            async let primaryResult = moduleScan(progressHandler)
            async let watchlistItems = scanEngine.scanAssistantTargets(assistantTargets)
            let result = await primaryResult
            currentScanModule = assistantTargets.isEmpty ? "Finalizing results" : "Checking assistant watchlist"
            scanProgress = max(scanProgress, 0.95)
            let persistentItems = try await watchlistItems
            let combined = deduplicated(items: result.items + persistentItems)
            scanFailures = result.failures.sorted {
                $0.moduleName.localizedStandardCompare($1.moduleName) == .orderedAscending
            }
            applyScanResults(combined, modules: modules)
            scanProgress = 1
        } catch is CancellationError {
            // User-initiated stop — not an error worth a banner.
        } catch {
            // Surface to the UI instead of swallowing into a console log.
            lastError = "Scan failed: \(error.localizedDescription)"
        }
    }

    private func deduplicated(items: [CleanupItem]) -> [CleanupItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = "\(item.module)|\(item.path.path)"
            return seen.insert(key).inserted
        }
    }
}

// MARK: - Feature Navigation (CleanMyMac-style structure)

enum FeatureSection: String, CaseIterable, Identifiable {
    case main = ""
    case cleanup = "Cleanup"
    case protection = "Protection"
    case speed = "Speed"
    case applications = "Applications"
    case files = "Files"

    var id: String { rawValue }

    var features: [Feature] {
        switch self {
        case .main:
            return [.smartScan, .assistant]
        case .cleanup:
            return [.systemJunk, .mailAttachments, .trashBins, .devTools, .cloudCleanup]
        case .protection:
            return [.malwareRemoval, .privacy]
        case .speed:
            return [.optimization, .networkCleanup, .batteryMonitor]
        case .applications:
            return [.uninstaller]  // updater, extensions, homebrewUpdater hidden from sidebar
        case .files:
            return [.spaceLens, .duplicateFiles, .similarPhotos, .shredder]
        }
    }
}

enum Feature: String, CaseIterable, Identifiable {
    // Main
    case smartScan = "Smart Care"
    case assistant = "Assistant"
    case share = "Share"

    // Cleanup
    case systemJunk = "System Junk"
    case mailAttachments = "Mail Attachments"
    case trashBins = "Trash Bins"
    case devTools = "Developer Tools"
    case aiAnalysis = "AI Analysis"
    case networkCleanup = "Network Cleanup"
    case cloudCleanup = "Cloud Cleanup"

    // Protection
    case malwareRemoval = "Malware Removal"
    case privacy = "Privacy"
    case loginItems = "Login Items"

    // Speed
    case optimization = "Optimization"
    case batteryMonitor = "Battery Monitor"
    case maintenance = "Maintenance"

    // Applications
    case uninstaller = "Uninstaller"
    case homebrewUpdater = "Homebrew Updater"
    case updater = "Updater"
    case extensions = "Extensions"

    // Files
    case spaceLens = "Space Lens"
    case largeOldFiles = "Large & Old Files"
    case duplicateFiles = "Duplicate Files"
    case similarPhotos = "Similar Photos"
    case shredder = "Shredder"

    var id: String { rawValue }

    var icon: String {
        switch self {
        // Main
        case .smartScan: return "sparkles.rectangle.stack"
        case .assistant: return "bubble.left"
        case .share: return "square.and.arrow.up"

        // Cleanup
        case .systemJunk: return "gearshape.2"
        case .mailAttachments: return "envelope"
        case .trashBins: return "trash"
        case .devTools: return "hammer"
        case .aiAnalysis: return "brain.head.profile"
        case .networkCleanup: return "network"
        case .cloudCleanup: return "icloud"

        // Protection
        case .malwareRemoval: return "shield.slash"
        case .privacy: return "hand.raised"
        case .loginItems: return "shield.lefthalf.filled"

        // Speed
        case .optimization: return "slider.horizontal.3"
        case .batteryMonitor: return "battery.100"
        case .maintenance: return "wrench.and.screwdriver"

        // Applications
        case .uninstaller: return "xmark.app"
        case .homebrewUpdater: return "arrow.up.circle"
        case .updater: return "arrow.clockwise.circle"
        case .extensions: return "puzzlepiece.extension"

        // Files
        case .spaceLens: return "chart.pie"
        case .largeOldFiles: return "doc.badge.clock"
        case .duplicateFiles: return "doc.on.doc"
        case .similarPhotos: return "photo.stack"
        case .shredder: return "scissors"
        }
    }

    var section: FeatureSection {
        switch self {
        case .smartScan, .assistant, .share: return .main
        case .systemJunk, .mailAttachments, .trashBins, .devTools, .aiAnalysis, .cloudCleanup: return .cleanup
        case .malwareRemoval, .privacy, .loginItems: return .protection
        case .optimization, .networkCleanup, .batteryMonitor, .maintenance: return .speed
        case .uninstaller, .homebrewUpdater, .updater, .extensions: return .applications
        case .spaceLens, .largeOldFiles, .duplicateFiles, .similarPhotos, .shredder: return .files
        }
    }
}

enum CompanionToolbarPreferences {
    static let storageCardVisible = "companion.toolbar.card.storage.visible"
    static let memoryCardVisible = "companion.toolbar.card.memory.visible"
    static let batteryCardVisible = "companion.toolbar.card.battery.visible"
    static let cpuCardVisible = "companion.toolbar.card.cpu.visible"
    static let networkCardVisible = "companion.toolbar.card.network.visible"
    static let devicesCardVisible = "companion.toolbar.card.devices.visible"
    static let smartCareCardVisible = "companion.toolbar.card.smartCare.visible"
}

enum CompanionToolbarCard: String, CaseIterable, Identifiable {
    case storage
    case memory
    case battery
    case cpu
    case network
    case devices
    case smartCare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storage: return "Macintosh HD"
        case .memory: return "Memory"
        case .battery: return "Battery"
        case .cpu: return "CPU"
        case .network: return "Wi-Fi"
        case .devices: return "Devices"
        case .smartCare: return "Smart Care"
        }
    }

    var icon: String {
        switch self {
        case .storage: return "internaldrive"
        case .memory: return "memorychip"
        case .battery: return "battery.100"
        case .cpu: return "cpu"
        case .network: return "wifi"
        case .devices: return "antenna.radiowaves.left.and.right"
        case .smartCare: return "magnifyingglass"
        }
    }

    var visibilityKey: String {
        switch self {
        case .storage: return CompanionToolbarPreferences.storageCardVisible
        case .memory: return CompanionToolbarPreferences.memoryCardVisible
        case .battery: return CompanionToolbarPreferences.batteryCardVisible
        case .cpu: return CompanionToolbarPreferences.cpuCardVisible
        case .network: return CompanionToolbarPreferences.networkCardVisible
        case .devices: return CompanionToolbarPreferences.devicesCardVisible
        case .smartCare: return CompanionToolbarPreferences.smartCareCardVisible
        }
    }
}
