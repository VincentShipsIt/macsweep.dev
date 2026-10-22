import Foundation

struct LocalTimeMachineSnapshot: Identifiable, Hashable, Sendable {
    let name: String
    let dateToken: String
    let created: Date
    let isDataless: Bool
    var id: String { name }
    var protectionPath: String { "/Volumes/com.apple.TimeMachine.localsnapshots/\(dateToken)" }
}

enum LocalSnapshotThinningTarget: Int64, CaseIterable, Identifiable, Sendable {
    case oneGiB = 1_073_741_824
    case fiveGiB = 5_368_709_120
    case tenGiB = 10_737_418_240
    var id: Int64 { rawValue }
    var title: String { "Request \(rawValue.formattedFileSize)" }
    var commandDescription: String {
        switch self {
        case .oneGiB: return "/usr/bin/tmutil thinlocalsnapshots / 1073741824 1"
        case .fiveGiB: return "/usr/bin/tmutil thinlocalsnapshots / 5368709120 1"
        case .tenGiB: return "/usr/bin/tmutil thinlocalsnapshots / 10737418240 1"
        }
    }
    var trustedScript: String {
        switch self {
        case .oneGiB:
            return Self.activityGuard + "\n/usr/bin/tmutil thinlocalsnapshots / 1073741824 1"
        case .fiveGiB:
            return Self.activityGuard + "\n/usr/bin/tmutil thinlocalsnapshots / 5368709120 1"
        case .tenGiB:
            return Self.activityGuard + "\n/usr/bin/tmutil thinlocalsnapshots / 10737418240 1"
        }
    }
    private static let activityGuard = #"""
        status="$(/usr/bin/tmutil status)" || exit 70
        count="$(/usr/bin/printf '%s\n' "$status" | /usr/bin/grep -Ec '^[[:space:]]*Running[[:space:]]*=')" || exit 71
        [ "$count" = "1" ] || exit 72
        inactive='^[[:space:]]*Running[[:space:]]*=[[:space:]]*0;[[:space:]]*$'
        /usr/bin/printf '%s\n' "$status" | /usr/bin/grep -Eq "$inactive" || exit 73
        """#

}

struct LocalSnapshotCapacity: Sendable {
    let available: VolumeSpaceSnapshot
    let importantUsageBytes: Int64?
    var reclaimableEstimate: Int64? {
        guard let free = available.availableBytes, let importantUsageBytes,
            free >= 0, importantUsageBytes >= free
        else { return nil }
        return importantUsageBytes - free
    }
    static func capture() -> Self {
        let root = URL(fileURLWithPath: "/")
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Self(
            available: .capture(at: root),
            importantUsageBytes: values?.volumeAvailableCapacityForImportantUsage)
    }
}

struct LocalSnapshotPermissions: Sendable {
    let hasFullDiskAccess: Bool
    let authorizationAvailable: Bool
    static func current() -> Self {
        Self(
            hasFullDiskAccess: FullDiskAccess.hasAccess,
            authorizationAvailable: FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript"))
    }
    var blocker: String? {
        if !hasFullDiskAccess { return "Grant Full Disk Access to MacSweep before thinning snapshots." }
        if !authorizationAvailable { return "Administrator authorization is unavailable on this host." }
        return nil
    }
}

struct LocalSnapshotInventory: Sendable {
    var snapshots: [LocalTimeMachineSnapshot] = []
    var issues: [String] = []
    var volumeID: String?
    var capacity: LocalSnapshotCapacity?
    var permissions = LocalSnapshotPermissions(hasFullDiskAccess: false, authorizationAvailable: false)
    var nativeSupported = false
    var isBackupRunning: Bool?
    var canThin: Bool {
        nativeSupported && issues.isEmpty && volumeID != nil && !snapshots.isEmpty
            && permissions.blocker == nil && isBackupRunning == false
    }
}

struct LocalSnapshotReceipt: Sendable {
    let commandCompleted: Bool
    let observedMissingIDs: [String]
    let observation: VolumeSpaceObservation?
    let beforeReclaimable: Int64?
    let afterReclaimable: Int64?
    let errors: [String]
    var result: CleanupResult {
        let observations = observation.map { [$0] } ?? []
        let accounting = CleanupAccounting(
            estimatedTargetBytes: 0, estimatedProcessedBytes: 0,
            movedToTrashBytes: 0, permanentlyRemovedTargetBytes: 0,
            removedLocalCopyBytes: 0, toolProcessedBytes: 0,
            volumeObservations: observations)
        return CleanupResult(
            itemsProcessed: observedMissingIDs.count, bytesFreed: 0,
            errors: errors.map { CleanupError(path: URL(fileURLWithPath: "/"), message: $0) },
            accounting: accounting)
    }
}

struct LocalSnapshotError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias LocalSnapshotCommand = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult
