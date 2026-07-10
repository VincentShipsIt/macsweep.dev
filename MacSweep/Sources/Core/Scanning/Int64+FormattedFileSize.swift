import Foundation

extension Int64 {
    /// This byte count formatted with the app-wide `.file` count style. The single
    /// source of truth behind every model's `formattedSize` and the views' inline
    /// size labels — replaces the hand-rolled `ByteCountFormatter.string(...)`
    /// idiom the models used to copy.
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
