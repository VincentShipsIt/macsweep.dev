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

    /// Last scan failure, surfaced to the UI. Cleared at the start of each scan.
    @Published var lastError: String?

    // MARK: - Disk Usage
    @Published var diskUsage: DiskUsage?

    // MARK: - Last Cleanup
    @Published var lastCleanup: CleanupResult?

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
    private var activeScanTask: Task<Void, Never>?
    private var activeScanID: UUID?

    // MARK: - Initialization
    init() {
        Task {
            await refreshDiskUsage()
        }
    }

    // MARK: - Actions

    func quickScan() async {
        await startScan(
            moduleScan: { progress in try await self.scanEngine.smartCareScan(progress: progress) },
            modules: SmartCareDefaults.moduleIDs,
            assistantTargets: assistant.enabledTargets
        )
    }

    func scan(modules: [String]? = nil) async {
        await startScan(
            moduleScan: { progress in try await self.scanEngine.scan(modules: modules, progress: progress) },
            modules: modules,
            assistantTargets: modules == nil ? assistant.enabledTargets : []
        )
    }

    func deleteSelected(dryRun: Bool = false) async throws -> CleanupResult {
        let itemsToDelete = scanResults.filter { selectedItems.contains($0.id) }

        let result = try await scanEngine.clean(items: itemsToDelete, dryRun: dryRun)

        if !dryRun {
            lastCleanup = result
            // Remove deleted items from results
            scanResults.removeAll { selectedItems.contains($0.id) }
            selectedItems.removeAll()
            smartCareSummary = scanResults.isEmpty
                ? nil
                : SmartCareAnalyzer().summarize(items: scanResults, diskUsage: diskUsage)
            await refreshDiskUsage()
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
        scanResults
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
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
                guard !plan.modules.isEmpty else { return [] }
                return try await scanEngine.scan(modules: plan.modules, progress: progress)
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
        moduleScan: @escaping (ScanProgressHandler?) async throws -> [CleanupItem],
        modules: [String]?,
        assistantTargets: [AssistantScanTarget]
    ) async {
        if let activeScanTask {
            await activeScanTask.value
            return
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
        moduleScan: @escaping (ScanProgressHandler?) async throws -> [CleanupItem],
        modules: [String]?,
        assistantTargets: [AssistantScanTarget]
    ) async {
        isScanning = true
        scanProgress = 0
        currentScanModule = "Preparing scan"
        scanResults = []
        selectedItems = []
        smartCareSummary = nil
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
            async let primaryItems = moduleScan(progressHandler)
            async let watchlistItems = scanEngine.scanAssistantTargets(assistantTargets)
            let scannedItems = try await primaryItems
            currentScanModule = assistantTargets.isEmpty ? "Finalizing results" : "Checking assistant watchlist"
            scanProgress = max(scanProgress, 0.95)
            let persistentItems = try await watchlistItems
            let combined = deduplicated(items: scannedItems + persistentItems)
            applyScanResults(combined, modules: modules)
            scanProgress = 1
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
            return [.systemJunk, .mailAttachments, .trashBins, .devTools, .networkCleanup, .cloudCleanup]
        case .protection:
            return [.malwareRemoval, .privacy]
        case .speed:
            return [.optimization, .batteryMonitor]
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
        case .smartScan, .assistant: return .main
        case .systemJunk, .mailAttachments, .trashBins, .devTools, .aiAnalysis, .networkCleanup, .cloudCleanup: return .cleanup
        case .malwareRemoval, .privacy, .loginItems: return .protection
        case .optimization, .batteryMonitor, .maintenance: return .speed
        case .uninstaller, .homebrewUpdater, .updater, .extensions: return .applications
        case .spaceLens, .largeOldFiles, .duplicateFiles, .similarPhotos, .shredder: return .files
        }
    }
}
