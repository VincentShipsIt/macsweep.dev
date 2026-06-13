import Foundation
import AppKit

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
    }

    /// Open System Preferences to the Full Disk Access pane
    static func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    /// Get the app's bundle identifier
    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.vincentshipsit.macsweep"
    }
}
