import Foundation

/// Shared sort options for the running-process list in Optimization.
///
/// The raw values and declaration order are the exact segmented-picker contract
/// shown by the view. Keeping the projection in Core makes every ordering
/// reachable from SwiftPM tests without coupling the behavior to SwiftUI.
enum RunningProcessSortOrder: String, CaseIterable, Hashable, Sendable {
    case memory = "Memory"
    case cpu = "CPU"
    case name = "Name"
}

extension Array where Element == RunningProcess {
    /// Returns the processes ordered by the selected Optimization sort mode.
    ///
    /// This preserves the original view behavior: resource usage is descending,
    /// while names use the user's localized ascending comparison.
    func sorted(using order: RunningProcessSortOrder) -> [RunningProcess] {
        switch order {
        case .memory:
            sorted { $0.memoryMB > $1.memoryMB }
        case .cpu:
            sorted { $0.cpuPercent > $1.cpuPercent }
        case .name:
            sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }
}
