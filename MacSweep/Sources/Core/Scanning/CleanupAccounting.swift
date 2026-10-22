import Foundation

public struct VolumeSpaceSnapshot: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let volumeID: String?
    public let volumePath: String
    public let availableBytes: Int64?
    public let errorMessage: String?
    public let metric: String

    init(timestamp: Date, volumeID: String?, volumePath: String, availableBytes: Int64?, errorMessage: String?, metric: String = "volumeAvailableCapacity") {
        self.timestamp = timestamp
        self.volumeID = volumeID
        self.volumePath = volumePath
        self.availableBytes = availableBytes
        self.errorMessage = errorMessage
        self.metric = metric
    }

    static func capture(at path: URL) -> VolumeSpaceSnapshot {
        do {
            let values = try path.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeAvailableCapacityKey])
            return VolumeSpaceSnapshot(timestamp: Date(), volumeID: values.volumeUUIDString,
                volumePath: path.path, availableBytes: values.volumeAvailableCapacity.map(Int64.init),
                errorMessage: values.volumeAvailableCapacity == nil ? "Available capacity was not reported" : nil)
        } catch {
            return VolumeSpaceSnapshot(timestamp: Date(), volumeID: nil, volumePath: path.path,
                availableBytes: nil, errorMessage: error.localizedDescription)
        }
    }
}

public struct VolumeSpaceObservation: Codable, Equatable, Sendable {
    public let before: VolumeSpaceSnapshot
    public let after: VolumeSpaceSnapshot
    public let observedAvailableChange: Int64?
    init(before: VolumeSpaceSnapshot, after: VolumeSpaceSnapshot) {
        self.before = before
        self.after = after
        if before.volumeID != nil, before.volumeID == after.volumeID,
           let start = before.availableBytes, let end = after.availableBytes {
            observedAvailableChange = end - start
        } else { observedAvailableChange = nil }
    }
}

public struct CleanupAccounting: Codable, Equatable, Sendable {
    public let estimatedTargetBytes: Int64
    public let estimatedProcessedBytes: Int64
    public let movedToTrashBytes: Int64
    public let permanentlyRemovedTargetBytes: Int64
    public let removedLocalCopyBytes: Int64
    public let toolProcessedBytes: Int64
    public let volumeObservations: [VolumeSpaceObservation]

    static func make(items: [CleanupItem], result: CleanupResult, observations: [VolumeSpaceObservation]) -> CleanupAccounting {
        let successful = items.filter { result.errors.failure(affecting: $0) == nil }
        func bytes(_ action: CleanupHistoryAction) -> Int64 {
            successful.filter { (result.historyActions[$0.id] ?? CleanupHistoryAction.action(for: $0)) == action }
                .estimatedBytes
        }
        return CleanupAccounting(
            estimatedTargetBytes: items.withoutOverlappingTargets().estimatedBytes,
            estimatedProcessedBytes: max(0, result.bytesFreed),
            movedToTrashBytes: bytes(.moveToTrash),
            permanentlyRemovedTargetBytes: bytes(.deletePermanently),
            removedLocalCopyBytes: bytes(.removeLocalDownload),
            toolProcessedBytes: bytes(.runToolCleanup), volumeObservations: observations
        )
    }

    static func snapshots(for items: [CleanupItem]) -> [VolumeSpaceSnapshot] {
        var volumes = Set<URL>()
        for item in items where item.path.isFileURL {
            let volume = try? item.path.resourceValues(forKeys: [.volumeURLKey]).volume
            volumes.insert(volume ?? item.path)
        }
        return volumes.sorted { $0.path < $1.path }.map { VolumeSpaceSnapshot.capture(at: $0) }
    }

    static func observations(since snapshots: [VolumeSpaceSnapshot]) -> [VolumeSpaceObservation] {
        snapshots.map { VolumeSpaceObservation(before: $0, after: .capture(at: URL(fileURLWithPath: $0.volumePath))) }
    }
}

extension CleanupResult {
    func processedTargetSizeText(estimateAvailable: Bool) -> String {
        let estimate = accounting?.estimatedProcessedBytes ?? bytesFreed
        return estimateAvailable
            ? "Processed target size: \(estimate.formattedFileSize) (estimate)" : "Processed target size unavailable"
    }

    func accounting(for items: [CleanupItem], observations: [VolumeSpaceObservation] = []) -> CleanupResult {
        CleanupResult(itemsProcessed: itemsProcessed, bytesFreed: bytesFreed, errors: errors,
            historyActions: historyActions, accounting: .make(items: items, result: self, observations: observations))
    }
}

extension Collection where Element == CleanupItem {
    var estimatedBytes: Int64 {
        reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(Swift.max(0, item.size))
            return overflow ? Int64.max : sum
        }
    }

    func withoutOverlappingTargets() -> [CleanupItem] {
        var paths: [(String, Bool)] = []
        var actions = Set<CleanupAction>()
        return sorted {
            if $0.path.pathComponents.count != $1.path.pathComponents.count {
                return $0.path.pathComponents.count < $1.path.pathComponents.count
            }
            return $0.module < $1.module
        }.filter { item in
            if case .action(let action) = item.target { return actions.insert(action).inserted }
            let path = item.path.standardizedFileURL.path
            guard !paths.contains(where: { path == $0.0 || ($0.1 && path.hasPrefix($0.0 + "/")) }) else { return false }
            paths.append((path, item.type == .directory))
            return true
        }
    }
}
