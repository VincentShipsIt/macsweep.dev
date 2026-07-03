import Foundation

/// Protocol for all cleanup modules
protocol ScanModule: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var icon: String { get }

    /// Scan for items that can be cleaned
    func scan() async throws -> [CleanupItem]

    /// Clean the specified items
    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult
}

extension ScanModule {
    /// Build a `CleanupItem` for a cache directory if it exists and has nonzero
    /// size; returns nil otherwise. Centralizes the
    /// exists → directorySize → size>0 → CleanupItem idiom the package-manager and
    /// dev-tools scanners repeat dozens of times. Behaviour is identical to the
    /// hand-written blocks, including the zero-size guard. Scan-only — the
    /// safety-gated deletion path in `clean()` is untouched.
    func scanCacheDirectory(
        at url: URL,
        moduleName displayName: String,
        type: CleanupItem.ItemType = .directory
    ) async -> CleanupItem? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try? await DiskAnalyzer.directorySize(at: url)) ?? 0
        guard size > 0 else { return nil }
        return CleanupItem(id: UUID(), path: url, size: size, type: type, module: id, moduleName: displayName)
    }

    /// Shared implementation for modules that clean `CleanupItem`s one by one.
    /// Keeps dry-run accounting, module filtering, and cleanup-time safety checks
    /// consistent while each module supplies its own removal strategy.
    func cleanItems(
        _ items: [CleanupItem],
        dryRun: Bool,
        blockedMessage: String = "Blocked by safety checks",
        errorMessage: @escaping (Error) -> String = { $0.localizedDescription },
        remove: (CleanupItem, SafetyChecker) async throws -> Void
    ) async -> CleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []
        let checker = SafetyChecker()

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
                continue
            }

            guard checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe else {
                errors.append(CleanupError(
                    path: item.path,
                    message: blockedMessage
                ))
                continue
            }

            do {
                try await remove(item, checker)
                processed += 1
                freed += item.size
            } catch {
                errors.append(CleanupError(
                    path: item.path,
                    message: errorMessage(error),
                    underlyingError: error
                ))
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Cleanup Item

struct CleanupItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let path: URL
    let size: Int64
    let type: ItemType
    let module: String
    let moduleName: String
    let lastModified: Date?

    enum ItemType: String, Sendable {
        case file
        case directory
        case symbolicLink
    }

    init(
        id: UUID,
        path: URL,
        size: Int64,
        type: ItemType,
        module: String,
        moduleName: String,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.size = size
        self.type = type
        self.module = module
        self.moduleName = moduleName
        self.lastModified = lastModified
    }

    var displayName: String {
        path.lastPathComponent
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: String {
        switch type {
        case .file: return "doc"
        case .directory: return "folder"
        case .symbolicLink: return "link"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CleanupItem, rhs: CleanupItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Cleanup Result

struct CleanupResult: Sendable {
    let itemsProcessed: Int
    let bytesFreed: Int64
    let errors: [CleanupError]
    let timestamp: Date

    var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }

    var isSuccess: Bool {
        errors.isEmpty
    }

    /// User-facing summary of per-item failures, or nil when everything succeeded.
    var failureSummaryMessage: String? {
        errors.failureSummaryMessage
    }

    init(itemsProcessed: Int, bytesFreed: Int64, errors: [CleanupError] = []) {
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.errors = errors
        self.timestamp = Date()
    }
}

struct CleanupError: Error, Sendable {
    let path: URL
    let message: String
    let underlyingError: Error?

    init(path: URL, message: String, underlyingError: Error? = nil) {
        self.path = path
        self.message = message
        self.underlyingError = underlyingError
    }
}

extension Array where Element == CleanupError {
    /// User-facing summary of per-item cleanup failures, or nil when empty.
    /// Wording stays generic on purpose: cleanup errors mix safety vetoes with
    /// ordinary deletion failures, so a blanket "blocked by safety checks" would
    /// mislabel the latter. The first error's own message carries the actual
    /// reason (safety-blocked items say so in their message).
    var failureSummaryMessage: String? {
        guard let first = first else { return nil }
        let itemCount = count == 1 ? "1 item" : "\(count) items"
        return "\(itemCount) couldn't be removed: \(first.message)"
    }
}

// MARK: - Disk Usage

struct DiskUsage: Sendable {
    let total: Int64
    let used: Int64
    let free: Int64

    var usedPercentage: Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }

    var freePercentage: Double {
        guard total > 0 else { return 0 }
        return Double(free) / Double(total)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
    }

    var formattedFree: String {
        ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }

    var formattedTotal: String {
        ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    static func current() async -> DiskUsage? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        do {
            let values = try home.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])

            guard let total = values.volumeTotalCapacity,
                  let free = values.volumeAvailableCapacityForImportantUsage
            else { return nil }

            return DiskUsage(
                total: Int64(total),
                used: Int64(total) - free,
                free: free
            )
        } catch {
            return nil
        }
    }
}
