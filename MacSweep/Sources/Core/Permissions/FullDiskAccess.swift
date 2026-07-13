import Foundation
import AppKit

enum FullDiskAccessScope {
    case smartCare
    case systemData
    case mail
    case safari

    var title: String {
        switch self {
        case .smartCare:
            return "Full Disk Access improves Smart Care"
        case .systemData:
            return "Full Disk Access is required for system data"
        case .mail:
            return "Full Disk Access is required for Apple Mail"
        case .safari:
            return "Full Disk Access is required for Safari"
        }
    }

    var detail: String {
        switch self {
        case .smartCare:
            return "Without access, Smart Care cannot fully inspect Apple Mail, Safari, or protected system data, so totals may be incomplete."
        case .systemData:
            return "Without access, protected system caches and logs are skipped, so an empty or smaller result may be incomplete."
        case .mail:
            return "Without access, Apple Mail attachments are skipped. Attachments from other supported mail apps may still appear."
        case .safari:
            return "Without access, Safari history and website data are skipped. Data from other supported browsers may still appear."
        }
    }
}

/// Handles Full Disk Access permission checking and requesting
struct FullDiskAccess {
    /// Check if the app has Full Disk Access
    static var hasAccess: Bool {
        #if DEBUG
        // Keep development relaunches passive. The explicit "Grant Access"
        // button still opens System Settings, but simply refreshing the debug app
        // should not probe protected locations and risk another TCC prompt.
        return false
        #else
        // Try to read a protected file that requires FDA
        let testPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari/History.db"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mail"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        ]

        for path in testPaths {
            if FileManager.default.isReadableFile(atPath: path.path) {
                return true
            }
        }

        // Alternative check: try to list contents of protected directory
        let protectedDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Safari")
        if let _ = try? FileManager.default.contentsOfDirectory(atPath: protectedDir.path) {
            return true
        }

        return false
        #endif
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
