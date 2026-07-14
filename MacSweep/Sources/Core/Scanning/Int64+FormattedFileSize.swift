import Foundation

public extension Int64 {
    /// This byte count formatted with the app-wide `.file` count style. The single
    /// source of truth behind every model's `formattedSize` and the views' inline
    /// size labels — replaces the hand-rolled `ByteCountFormatter.string(...)`
    /// idiom the models used to copy. `public` so it is reachable across the
    /// package boundary from the `MacSweepCLIKit` target, not just the app module.
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
