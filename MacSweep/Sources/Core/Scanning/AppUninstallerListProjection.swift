import Foundation

/// Stable sort options for the App Uninstaller's installed-app list.
///
/// The raw values are the exact labels displayed by the segmented picker. This
/// contract lives in MacSweepCore so the ordering behavior remains testable
/// without importing the SwiftUI-only feature target.
enum AppUninstallerSortOrder: String, CaseIterable, Hashable, Sendable {
    case name = "Name"
    case size = "Size"
    case lastUsed = "Last Used"
}

extension Array where Element == InstalledApp {
    /// Filters installed apps by display name or bundle identifier, then applies
    /// the ordering selected in App Uninstaller.
    func appList(matching query: String, sortedBy order: AppUninstallerSortOrder) -> [InstalledApp] {
        var apps = self

        if !query.isEmpty {
            apps = apps.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
            }
        }

        switch order {
        case .name:
            apps.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .size:
            apps.sort { $0.totalSize > $1.totalSize }
        case .lastUsed:
            apps.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        }

        return apps
    }
}
