// Pure navigation metadata shared by the app and package tests. Keeping labels
// and symbols here makes the keyboard/sidebar accessibility contract testable
// without importing SwiftUI.

enum FeatureSection: String, CaseIterable, Identifiable {
    case main = ""
    case cleanup = "Cleanup"
    case protection = "Protection"
    case speed = "Speed"
    case applications = "Applications"
    case files = "Files"
    case developer = "Developer"

    var id: String { rawValue }

    var features: [Feature] {
        switch self {
        case .main:
            return [.smartScan, .assistant, .cleanupHistory]
        case .cleanup:
            return [.systemJunk, .mailAttachments, .trashBins, .devTools, .aiAnalysis, .cloudCleanup]
        case .protection:
            return [.malwareRemoval, .privacy, .loginItems]
        case .speed:
            return [.optimization, .networkCleanup, .batteryMonitor, .maintenance]
        case .applications:
            return [.uninstaller, .homebrewUpdater]
        case .files:
            return [.spaceLens, .duplicateFiles, .similarPhotos, .shredder]
        case .developer:
            return [.developerLogs]
        }
    }
}

enum Feature: String, CaseIterable, Identifiable {
    case smartScan = "Smart Care"
    case assistant = "Assistant"
    case share = "Share"
    case cleanupHistory = "Cleanup History"

    case systemJunk = "System Junk"
    case mailAttachments = "Mail Attachments"
    case trashBins = "Trash Bins"
    case devTools = "Developer Tools"
    case aiAnalysis = "AI Analysis"
    case networkCleanup = "Network Cleanup"
    case cloudCleanup = "Cloud Cleanup"

    case malwareRemoval = "Malware Removal"
    case privacy = "Privacy"
    case loginItems = "Login Items"

    case optimization = "Optimization"
    case batteryMonitor = "Battery Monitor"
    case maintenance = "Maintenance"

    case uninstaller = "Uninstaller"
    case homebrewUpdater = "Homebrew Updater"

    case spaceLens = "Space Lens"
    case largeOldFiles = "Large & Old Files"
    case duplicateFiles = "Duplicate Files"
    case similarPhotos = "Similar Photos"
    case shredder = "Shredder"

    case developerLogs = "Logs"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .smartScan: return "sparkles.rectangle.stack"
        case .assistant: return "bubble.left"
        case .share: return "square.and.arrow.up"
        case .cleanupHistory: return "clock.arrow.circlepath"
        case .systemJunk: return "gearshape.2"
        case .mailAttachments: return "envelope"
        case .trashBins: return "trash"
        case .devTools: return "hammer"
        case .aiAnalysis: return "brain.head.profile"
        case .networkCleanup: return "network"
        case .cloudCleanup: return "icloud"
        case .malwareRemoval: return "shield.slash"
        case .privacy: return "hand.raised"
        case .loginItems: return "shield.lefthalf.filled"
        case .optimization: return "slider.horizontal.3"
        case .batteryMonitor: return "battery.100"
        case .maintenance: return "wrench.and.screwdriver"
        case .uninstaller: return "xmark.app"
        case .homebrewUpdater: return "arrow.up.circle"
        case .spaceLens: return "chart.pie"
        case .largeOldFiles: return "doc.badge.clock"
        case .duplicateFiles: return "doc.on.doc"
        case .similarPhotos: return "photo.stack"
        case .shredder: return "scissors"
        case .developerLogs: return "list.bullet.rectangle"
        }
    }

    var section: FeatureSection {
        switch self {
        case .smartScan, .assistant, .share, .cleanupHistory: return .main
        case .systemJunk, .mailAttachments, .trashBins, .devTools, .aiAnalysis, .cloudCleanup: return .cleanup
        case .malwareRemoval, .privacy, .loginItems: return .protection
        case .optimization, .networkCleanup, .batteryMonitor, .maintenance: return .speed
        case .uninstaller, .homebrewUpdater: return .applications
        case .spaceLens, .largeOldFiles, .duplicateFiles, .similarPhotos, .shredder: return .files
        case .developerLogs: return .developer
        }
    }
}

/// Shared expansion targets for the Dashboard and Menu Bar detail surfaces.
enum WidgetType: String, CaseIterable {
    case storage, memory, battery, cpu, network, devices, system
}

enum DeveloperModePreferences {
    static let enabledKey = "developerModeEnabled"
}
