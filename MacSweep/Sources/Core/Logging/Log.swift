import Foundation
import os

/// Structured logging facade over `os.Logger` plus MacSweep's local audit file.
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
/// Deletions and selected diagnostics are also written to `AppLogStore`, which
/// powers the Developer Logs page. Paths and module ids are public in unified
/// logging on purpose: the value of a deletion audit is being able to read
/// exactly what was removed and by which module. This is the user's own machine
/// acting on the user's own files; nothing logged here leaves the device unless
/// the user explicitly exports it.
enum Log {
    private static let subsystem = "dev.macsweep"

    private static let safety = Logger(subsystem: subsystem, category: "safety")
    private static let scan = Logger(subsystem: subsystem, category: "scan")
    private static let process = Logger(subsystem: subsystem, category: "process")

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
            let detail = "delete failed [\(module)] \(disposition.rawValue) \(path.path): \(error.localizedDescription)"
            safety.error("\(detail, privacy: .public)")
        } else {
            let detail = "deleted [\(module)] \(disposition.rawValue) \(path.path)"
            safety.notice("\(detail, privacy: .public)")
        }

        AppLogStore.shared.record(AppLogEvent(
            category: .deletion,
            level: error == nil ? .notice : .error,
            message: error == nil ? disposition.successMessage : disposition.failureMessage,
            module: module,
            path: path.path,
            action: disposition.rawValue,
            errorMessage: error?.localizedDescription
        ))
    }

    static func scanError(_ message: String) {
        scan.error("\(message, privacy: .public)")
        AppLogStore.shared.record(AppLogEvent(
            category: .scan,
            level: .error,
            message: message
        ))
    }

    static func processDebug(_ message: String) {
        process.debug("\(message, privacy: .public)")
        AppLogStore.shared.record(AppLogEvent(
            category: .process,
            level: .debug,
            message: message
        ))
    }
}

private extension Log.Disposition {
    var successMessage: String {
        switch self {
        case .trash: return "Moved to Trash"
        case .delete: return "Deleted permanently"
        case .shred: return "Securely shredded"
        }
    }

    var failureMessage: String {
        switch self {
        case .trash: return "Move to Trash failed"
        case .delete: return "Permanent deletion failed"
        case .shred: return "Secure shred failed"
        }
    }
}
