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
    /// or the volume has no Trash.
    static func recoverable(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Permanently delete the item. Only for modules whose purpose is irreversible
    /// removal.
    static func permanent(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
