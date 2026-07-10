import Darwin
import Foundation

/// Centralizes how cleanup modules dispose of files.
///
/// `recoverable` moves the item to the user's Trash so a mistaken cleanup can be
/// undone from Finder. `permanent` deletes outright — used only where recovery is
/// meaningless or contrary to intent (emptying the Trash, secure shredding).
///
/// Regenerable system junk (system/browser caches) is deleted permanently by its
/// own modules: trashing it would not free disk space until the Trash is emptied
/// and it is recreated on demand anyway. Anything the user might regret losing —
/// assistant-watchlist targets, AI-suggested deletions, privacy artifacts,
/// package-manager stores, network config — is routed through `recoverable`.
enum CleanupFileRemover {
    /// Move the item to the Trash (reversible). Throws if the item does not exist
    /// or the volume has no Trash. `module` attributes the deletion in the safety
    /// audit log.
    static func recoverable(_ url: URL, module: String) throws {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            Log.deletion(path: url, module: module, disposition: .trash, error: error)
            throw error
        }
        Log.deletion(path: url, module: module, disposition: .trash)
    }

    /// Permanently delete the item. Only for modules whose purpose is irreversible
    /// removal. `module` attributes the deletion in the safety audit log.
    static func permanent(_ url: URL, module: String) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.deletion(path: url, module: module, disposition: .delete, error: error)
            throw error
        }
        Log.deletion(path: url, module: module, disposition: .delete)
    }

    /// Permanently remove an empty directory without recursively deleting any
    /// children that may arrive after the caller's safety validation. `rmdir` is
    /// atomic with respect to emptiness: it fails rather than removing a late
    /// arrival, including a protected descendant.
    static func permanentEmptyDirectory(_ url: URL, module: String) throws {
        let status = url.path.withCString { Darwin.rmdir($0) }
        guard status == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Log.deletion(path: url, module: module, disposition: .delete, error: error)
            throw error
        }
        Log.deletion(path: url, module: module, disposition: .delete)
    }
}
