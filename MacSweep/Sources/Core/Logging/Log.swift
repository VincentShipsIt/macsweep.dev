import Foundation
import os

/// Minimal logging facade over `os.Logger`.
///
/// MacSweep irreversibly deletes user files; before this facade existed there was
/// no repo-wide logging at all, so a bad deletion left no trace to diagnose after
/// the fact. Three categories keep the unified-log output filterable in
/// Console.app (`subsystem: dev.macsweep`):
///
///   • `safety`  — every deletion (path + module + result) and safety decisions.
///   • `scan`    — scan / cleanup lifecycle and best-effort scan failures.
///   • `process` — subprocess and system-command failures in best-effort paths.
///
/// Paths and module ids are logged with `.public` privacy on purpose: the entire
/// value of a deletion audit is being able to read exactly what was removed and
/// by which module. This is the user's own machine acting on the user's own
/// files; nothing logged here leaves the device.
enum Log {
    private static let subsystem = "dev.macsweep"

    static let safety = Logger(subsystem: subsystem, category: "safety")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let process = Logger(subsystem: subsystem, category: "process")

    /// How a file was removed, for the deletion audit line.
    enum Disposition: String {
        case trash          // moved to Trash (recoverable)
        case delete         // permanently removed
        case shred          // securely overwritten then removed
    }

    /// Record a single deletion attempt on the `safety` log: what was removed, by
    /// which module, how, and whether it succeeded. Success is `.notice`; failure
    /// is `.error` with the underlying reason.
    static func deletion(
        path: URL,
        module: String,
        disposition: Disposition,
        error: Error? = nil
    ) {
        if let error {
            safety.error(
                "delete failed [\(module, privacy: .public)] \(disposition.rawValue, privacy: .public) \(path.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        } else {
            safety.notice(
                "deleted [\(module, privacy: .public)] \(disposition.rawValue, privacy: .public) \(path.path, privacy: .public)"
            )
        }
    }
}
