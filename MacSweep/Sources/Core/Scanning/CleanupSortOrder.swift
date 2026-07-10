import Foundation

/// Shared sort options for `CleanupItem` result lists.
///
/// Several feature views (Cloud Cleanup, Similar Photos, Duplicate Files, Large &
/// Old Files) each declared their own private `SortOrder` enum plus an identical
/// `switch` that sorted the list. This is the single source of truth for both.
///
/// The raw values are the exact menu labels those views display, so a view can
/// keep its picker verbatim by iterating one of the ordered `cases` lists below —
/// the option set and order stay unchanged, only the duplication goes away.
enum CleanupSortOrder: String, CaseIterable, Hashable, Sendable {
    case sizeDesc = "Largest First"
    case sizeAsc = "Smallest First"
    case dateDesc = "Newest First"
    case dateAsc = "Oldest First"
    case nameAsc = "Name A-Z"

    /// Options shown by the size/date/name result lists (Cloud Cleanup, Similar
    /// Photos, Duplicate Files), in their original picker order.
    static let standardCases: [CleanupSortOrder] = [.sizeDesc, .dateAsc, .dateDesc, .nameAsc]

    /// Options shown by Large & Old Files, which additionally offers smallest-first.
    static let largeFileCases: [CleanupSortOrder] = [.sizeDesc, .sizeAsc, .dateDesc, .dateAsc, .nameAsc]
}

extension Array where Element == CleanupItem {
    /// Returns the items ordered by `order`. Mirrors the hand-rolled sort switch
    /// the feature views used to copy, including the `distantPast` fallback for
    /// items with no modification date and the localized name comparison.
    func sorted(using order: CleanupSortOrder) -> [CleanupItem] {
        var items = self
        switch order {
        case .sizeDesc:
            items.sort { $0.size > $1.size }
        case .sizeAsc:
            items.sort { $0.size < $1.size }
        case .dateDesc:
            items.sort { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .dateAsc:
            items.sort { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        case .nameAsc:
            items.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        }
        return items
    }
}
