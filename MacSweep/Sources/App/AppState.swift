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
            return "paintbrush.pointed"
        }
    }

    // MARK: - Engines
    let scanEngine = ScanEngine()
    let safetyChecker = SafetyChecker()

    // MARK: - Initialization
    init() {
        Task {
            await refreshDiskUsage()
        }
    }

    // MARK: - Actions

    func quickScan() async {
        isScanning = true
        scanProgress = 0
        scanResults = []

        defer { isScanning = false }

        do {
            let items = try await scanEngine.scan()
            scanResults = items
        } catch {
            print("Scan failed: \(error)")
        }
    }

    func scan(modules: [String]? = nil) async {
        isScanning = true
        scanProgress = 0
        scanResults = []

        defer { isScanning = false }

        do {
            let items = try await scanEngine.scan(modules: modules)
            scanResults = items.sorted { $0.size > $1.size }
        } catch {
            print("Scan failed: \(error)")
        }
    }

    func deleteSelected(dryRun: Bool = false) async throws -> CleanupResult {
        let itemsToDelete = scanResults.filter { selectedItems.contains($0.id) }

        let result = try await scanEngine.clean(items: itemsToDelete, dryRun: dryRun)

        if !dryRun {
            lastCleanup = result
            // Remove deleted items from results
            scanResults.removeAll { selectedItems.contains($0.id) }
            selectedItems.removeAll()
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

    func deselectAll() {
        selectedItems.removeAll()
    }

    var selectedSize: Int64 {
        scanResults
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
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
            return [.smartScan]
        case .cleanup:
            return [.systemJunk, .mailAttachments, .trashBins, .devTools, .aiAnalysis, .networkCleanup]
        case .protection:
            return [.privacy]  // malwareRemoval hidden until implemented
        case .speed:
            return [.optimization, .maintenance]
        case .applications:
            return [.uninstaller]  // updater, extensions hidden until implemented
        case .files:
            return [.spaceLens, .largeOldFiles, .shredder]
        }
    }
}

enum Feature: String, CaseIterable, Identifiable {
    // Main
    case smartScan = "Smart Scan"

    // Cleanup
    case systemJunk = "System Junk"
    case mailAttachments = "Mail Attachments"
    case trashBins = "Trash Bins"
    case devTools = "Developer Tools"
    case aiAnalysis = "AI Analysis"
    case networkCleanup = "Network Cleanup"

    // Protection
    case malwareRemoval = "Malware Removal"
    case privacy = "Privacy"
    case loginItems = "Login Items"

    // Speed
    case optimization = "Optimization"
    case maintenance = "Maintenance"

    // Applications
    case uninstaller = "Uninstaller"
    case updater = "Updater"
    case extensions = "Extensions"

    // Files
    case spaceLens = "Space Lens"
    case largeOldFiles = "Large & Old Files"
    case shredder = "Shredder"

    var id: String { rawValue }

    var icon: String {
        switch self {
        // Main
        case .smartScan: return "sparkles.rectangle.stack"

        // Cleanup
        case .systemJunk: return "gearshape.2"
        case .mailAttachments: return "envelope"
        case .trashBins: return "trash"
        case .devTools: return "hammer"
        case .aiAnalysis: return "brain.head.profile"
        case .networkCleanup: return "network"

        // Protection
        case .malwareRemoval: return "ladybug"
        case .privacy: return "hand.raised"
        case .loginItems: return "shield.lefthalf.filled"

        // Speed
        case .optimization: return "slider.horizontal.3"
        case .maintenance: return "wrench.and.screwdriver"

        // Applications
        case .uninstaller: return "xmark.app"
        case .updater: return "arrow.clockwise.circle"
        case .extensions: return "puzzlepiece.extension"

        // Files
        case .spaceLens: return "chart.pie"
        case .largeOldFiles: return "doc.badge.clock"
        case .shredder: return "scissors"
        }
    }

    var section: FeatureSection {
        switch self {
        case .smartScan: return .main
        case .systemJunk, .mailAttachments, .trashBins, .devTools, .aiAnalysis, .networkCleanup: return .cleanup
        case .malwareRemoval, .privacy, .loginItems: return .protection
        case .optimization, .maintenance: return .speed
        case .uninstaller, .updater, .extensions: return .applications
        case .spaceLens, .largeOldFiles, .shredder: return .files
        }
    }
}
