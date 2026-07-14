import Foundation

extension Sequence where Element == CleanupItem {
    /// Raw byte total of the sequence — optionally restricted to the items whose
    /// ids are in `selected`.
    func totalSize(selected: Set<UUID>? = nil) -> Int64 {
        reduce(into: Int64(0)) { total, item in
            guard selected == nil || selected?.contains(item.id) == true else { return }
            total += item.size
        }
    }

    /// `totalSize(selected:)` formatted with the app-wide `.file` count style.
    /// Replaces the hand-rolled filter+reduce+ByteCountFormatter idiom the views
    /// used to copy.
    func formattedTotalSize(selected: Set<UUID>? = nil) -> String {
        totalSize(selected: selected).formattedFileSize
    }
}
