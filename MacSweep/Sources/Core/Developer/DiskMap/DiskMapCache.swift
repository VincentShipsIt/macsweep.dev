import Darwin
import Foundation

/// Small, optional metadata index. No cleanup candidates or deletion authority are persisted here.
actor DiskMapCache {
    struct Record: Codable, Sendable {
        var node: DiskMapNode
        var hardLinks: Set<String>
        var measuredAt = Date()
    }
    struct Entry: Codable, Sendable {
        var key: String
        var report: DiskMapReport
        var records: [String: Record]
    }
    static let shared = DiskMapCache(file: URL.cachesDirectory.appending(path: "MacSweep/developer-disk-map-v1.json"))
    static let maximumIndexBytes = 262_144
    static let minimumFreeBytes: Int64 = 1_073_741_824
    private let file: URL?
    private var memory: [String: Entry] = [:]
    private var loaded = false
    let ttl: TimeInterval

    init(file: URL? = nil, ttl: TimeInterval = 300) {
        self.file = file
        self.ttl = ttl
    }

    func get(_ key: String, now: Date = Date()) -> Entry? {
        if !loaded {
            loaded = true
            if let file, let entry = read(file) { memory[entry.key] = entry }
        }
        guard let memory = memory[key],
            now.timeIntervalSince(memory.report.measuredAt) >= 0,
            now.timeIntervalSince(memory.report.measuredAt) < ttl
        else { return nil }
        return memory
    }

    func put(_ entry: Entry, freeBytes: Int64?) async -> Bool {
        loaded = true
        memory[entry.key] = entry
        if memory.count > 2, let oldest = memory.values.min(by: { $0.report.measuredAt < $1.report.measuredAt }) {
            memory.removeValue(forKey: oldest.key)
        }
        guard let file, let freeBytes, freeBytes >= Self.minimumFreeBytes,
            entry.report.finished, entry.report.issues.isEmpty,
            entry.report.roots.allSatisfy({ $0.coverage == .complete }),
            entry.records.count <= 128,
            let data = try? JSONEncoder().encode(entry), data.count <= Self.maximumIndexBytes
        else { return false }
        return
            (try? await DevArtifactIO.run {
                let parent = file.deletingLastPathComponent()
                guard Self.noSymlinkAncestors(parent), Self.noSymlinkAncestors(file) else { return false }
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                return true
            }) ?? false
    }

    private func read(_ file: URL) -> Entry? {
        guard Self.noSymlinkAncestors(file) else { return nil }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: Self.maximumIndexBytes + 1),
            data.count <= Self.maximumIndexBytes
        else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func noSymlinkAncestors(_ url: URL) -> Bool {
        var path = DiskMapRoots.physicalSystemAlias(url)
        while path.path != "/" {
            var value = stat()
            if lstat(path.path, &value) == 0 && value.st_mode & S_IFMT == S_IFLNK { return false }
            path.deleteLastPathComponent()
        }
        return true
    }
}
