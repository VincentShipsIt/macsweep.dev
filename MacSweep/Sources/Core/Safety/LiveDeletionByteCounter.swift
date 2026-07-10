import Darwin
import Foundation

/// Strict, live allocated-byte accounting for filesystem deletion preflight.
///
/// This deliberately does not reuse `DiskAnalyzer`: scan-time sizing is
/// best-effort and may skip unreadable or hidden entries, while a destructive
/// preflight must either produce a complete live total or fail closed.
struct LiveDeletionByteCounter {
    enum MeasurementError: Error, Equatable {
        case invalidLimit
        case missingPath(String)
        case cannotRead(path: String, code: Int32)
        case cannotEnumerate(String)
        case changedDuringMeasurement(String)
        case invalidByteCount(String)
        case arithmeticOverflow
        case limitExceeded
    }

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            inode = UInt64(status.st_ino)
        }
    }

    private struct DirectorySnapshot: Equatable {
        let identity: FileIdentity
        let fileType: mode_t
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init(_ status: stat) {
            identity = FileIdentity(status)
            fileType = status.st_mode & S_IFMT
            modificationSeconds = Int64(status.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changeSeconds = Int64(status.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }

    private struct ByteAccumulator {
        let limit: Int64
        private(set) var total: Int64 = 0

        init(limit: Int64) throws {
            guard limit >= 0 else { throw MeasurementError.invalidLimit }
            self.limit = limit
        }

        mutating func add(_ byteCount: Int64, path: String) throws {
            guard byteCount >= 0 else {
                throw MeasurementError.invalidByteCount(path)
            }

            let (nextTotal, overflow) = total.addingReportingOverflow(byteCount)
            guard !overflow else { throw MeasurementError.arithmeticOverflow }
            guard nextTotal <= limit else { throw MeasurementError.limitExceeded }
            total = nextTotal
        }
    }

    private struct MeasurementState {
        var seen: Set<FileIdentity> = []
        var bytes: ByteAccumulator
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Returns the allocated bytes reachable from `roots`, stopping as soon as
    /// the total is known to exceed `limit`.
    ///
    /// Hidden children are included. Every node is inspected with `lstat`, so a
    /// final-component symlink contributes only its own inode allocation and its
    /// target is never followed. Parent-component symlinks retain normal POSIX
    /// lookup semantics because deletion through such a path reaches that same
    /// parent target. `(device, inode)` identity deduplicates duplicate, hard-link,
    /// and parent/child-overlapping selections.
    func totalAllocatedBytes(for roots: [URL], limit: Int64) throws -> Int64 {
        var state = MeasurementState(bytes: try ByteAccumulator(limit: limit))

        for root in roots.sorted(by: Self.pathOrder) {
            try measure(root.standardizedFileURL, state: &state)
        }

        return state.bytes.total
    }

    /// Exercises the same checked accumulator used by live traversal without
    /// requiring impractically large fixtures.
    static func checkedTotal(of byteCounts: [Int64], limit: Int64) throws -> Int64 {
        var accumulator = try ByteAccumulator(limit: limit)
        for byteCount in byteCounts {
            try accumulator.add(byteCount, path: "<measured-total>")
        }
        return accumulator.total
    }

    private func measure(_ url: URL, state: inout MeasurementState) throws {
        let status = try status(at: url)
        let identity = FileIdentity(status)

        guard state.seen.insert(identity).inserted else { return }

        try state.bytes.add(allocatedByteCount(for: status, at: url), path: url.path)

        // Explicit no-follow semantics: only a real directory reached by lstat
        // is traversed. A directory symlink is an S_IFLNK leaf.
        guard (status.st_mode & S_IFMT) == S_IFDIR else { return }
        let before = DirectorySnapshot(status)

        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            ).sorted(by: Self.pathOrder)
        } catch {
            try verifyDirectory(at: url, stillMatches: before)
            throw MeasurementError.cannotEnumerate(url.path)
        }

        for child in children {
            try measure(child, state: &state)
        }

        // A concurrent add/remove/replace can make a seemingly complete walk
        // omit bytes. Refuse that unstable snapshot rather than deleting from it.
        try verifyDirectory(at: url, stillMatches: before)
    }

    private func verifyDirectory(at url: URL, stillMatches before: DirectorySnapshot) throws {
        let after: stat
        do {
            after = try status(at: url)
        } catch {
            throw MeasurementError.changedDuringMeasurement(url.path)
        }

        guard DirectorySnapshot(after) == before else {
            throw MeasurementError.changedDuringMeasurement(url.path)
        }
    }

    private func status(at url: URL) throws -> stat {
        var value = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &value)
        }

        guard result == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                throw MeasurementError.missingPath(url.path)
            }
            throw MeasurementError.cannotRead(path: url.path, code: code)
        }

        return value
    }

    private func allocatedByteCount(for status: stat, at url: URL) throws -> Int64 {
        let blocks = Int64(status.st_blocks)
        guard blocks >= 0 else {
            throw MeasurementError.invalidByteCount(url.path)
        }

        // POSIX st_blocks is expressed in 512-byte units, independent of the
        // filesystem's allocation block size.
        let (byteCount, overflow) = blocks.multipliedReportingOverflow(by: 512)
        guard !overflow else { throw MeasurementError.arithmeticOverflow }
        return byteCount
    }

    private static func pathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path < rhs.standardizedFileURL.path
    }
}
