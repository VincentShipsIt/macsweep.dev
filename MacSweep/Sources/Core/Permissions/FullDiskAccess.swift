import Foundation
import AppKit

enum FullDiskAccessScope {
    case smartCare
    case systemData
    case mail
    case trash
    case safari

    var title: String {
        switch self {
        case .smartCare:
            return "Full Disk Access is required for Smart Care"
        case .systemData:
            return "Full Disk Access is required for system data"
        case .mail:
            return "Full Disk Access is required for Apple Mail"
        case .trash:
            return "Full Disk Access is required for Trash"
        case .safari:
            return "Full Disk Access is required for Safari"
        }
    }

    var detail: String {
        switch self {
        case .smartCare:
            return "Smart Care stays disabled until it can inspect Apple Mail, Safari, "
                + "and protected system data without returning partial results."
        case .systemData:
            return "Without access, protected system caches and logs are skipped, "
                + "so an empty or smaller result may be incomplete."
        case .mail:
            return "Mail attachment scanning and cleanup stay disabled until Apple Mail "
                + "and other supported mail sources can be checked together."
        case .trash:
            return "Without access, macOS blocks MacSweep from listing your Trash, "
                + "so an empty result cannot be verified."
        case .safari:
            return "Privacy scanning and cleanup stay disabled until Safari history "
                + "and website data can be checked without returning partial results."
        }
    }

    var actionBlockedMessage: String {
        switch self {
        case .smartCare:
            return "Grant Full Disk Access before running Smart Care."
        case .systemData:
            return "Grant Full Disk Access before scanning or cleaning system data."
        case .mail:
            return "Grant Full Disk Access before scanning or cleaning Mail attachments."
        case .trash:
            return "Grant Full Disk Access before scanning or emptying Trash bins."
        case .safari:
            return "Grant Full Disk Access before scanning or cleaning Safari data."
        }
    }
}

/// Handles Full Disk Access permission checking and requesting
struct FullDiskAccess {
    /// Check if the app has Full Disk Access
    static var hasAccess: Bool {
        // Try to read a protected file that requires FDA
        let testPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari/History.db"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mail"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        ]

        for path in testPaths where FileManager.default.isReadableFile(atPath: path.path) {
            return true
        }

        // Alternative check: try to list contents of protected directory
        let protectedDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari")
        if (try? FileManager.default.contentsOfDirectory(atPath: protectedDir.path)) != nil {
            return true
        }

        return false
    }

    /// Open System Preferences to the Full Disk Access pane
    static func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Get the app's bundle identifier
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "dev.macsweep.app"
    }
}
