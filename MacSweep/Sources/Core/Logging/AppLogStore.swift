import Foundation
import os

enum AppLogCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case deletion
    case scan
    case process

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deletion: return "Deletions"
        case .scan: return "Scans"
        case .process: return "Processes"
        }
    }
}

enum AppLogLevel: String, Codable, Sendable {
    case debug
    case notice
    case error
}

/// One structured, local-only diagnostic event. Deletion events retain the
/// original path, module, and disposal method so a cleanup can be audited after
/// the source item no longer exists.
struct AppLogEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: AppLogCategory
    let level: AppLogLevel
    let message: String
    let module: String?
    let path: String?
    let action: String?
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: AppLogCategory,
        level: AppLogLevel,
        message: String,
        module: String? = nil,
        path: String? = nil,
        action: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.module = module
        self.path = path
        self.action = action
        self.errorMessage = errorMessage
    }

    var searchableText: String {
        [message, module, path, action, errorMessage]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// Durable newline-delimited JSON log owned by MacSweep.
///
/// Unified logging remains the primary system diagnostic surface, while this
/// store gives the app a bounded, corruption-tolerant audit trail it can render
/// and export itself. Each append completes before `record` returns. A partial
/// or malformed line is ignored without hiding the rest of the file.
final class AppLogStore: @unchecked Sendable {
    private static let fallbackLogger = Logger(
        subsystem: "dev.macsweep",
        category: "logging"
    )

    static let shared: AppLogStore = {
        let processName = ProcessInfo.processInfo.processName
        let isTestProcess = processName.contains("PackageTests")
            || processName.hasSuffix("Tests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return AppLogStore(inMemory: isTestProcess)
    }()

    static let defaultMaxEntries = 5_000
    static let defaultMaxAgeDays = 180
    static let defaultMaxFileBytes: UInt64 = 5 * 1_024 * 1_024

    let fileURL: URL

    private let queue = DispatchQueue(label: "dev.macsweep.app-log")
    private let maxEntries: Int
    private let maxAgeDays: Int
    private let maxFileBytes: UInt64
    private let inMemory: Bool
    private var memoryEvents: [AppLogEvent] = []

    init(
        fileURL: URL? = nil,
        inMemory: Bool = false,
        maxEntries: Int = AppLogStore.defaultMaxEntries,
        maxAgeDays: Int = AppLogStore.defaultMaxAgeDays,
        maxFileBytes: UInt64 = AppLogStore.defaultMaxFileBytes
    ) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.inMemory = inMemory
        self.maxEntries = max(1, maxEntries)
        self.maxAgeDays = max(1, maxAgeDays)
        self.maxFileBytes = max(1_024, maxFileBytes)
    }

    var events: [AppLogEvent] {
        queue.sync {
            let loaded = inMemory ? memoryEvents : loadEvents()
            return pruned(loaded)
        }
    }

    func record(_ event: AppLogEvent) {
        queue.sync {
            if inMemory {
                memoryEvents.append(event)
                memoryEvents = pruned(memoryEvents)
                return
            }

            do {
                try append(event)
                if fileSize() > maxFileBytes {
                    try rewrite(eventsFittingFileLimit(pruned(loadEvents())))
                }
            } catch {
                // Unified logging still contains the event. Never make cleanup
                // fail just because its secondary on-disk audit could not write.
                Self.fallbackLogger.error(
                    "App-owned log write failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func clear() {
        queue.sync {
            memoryEvents.removeAll()
            guard !inMemory else { return }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MacSweep", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("app-log.ndjson", isDirectory: false)
    }

    private func append(_ event: AppLogEvent) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        var line = try makeEncoder().encode(event)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private func loadEvents() -> [AppLogEvent] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = makeDecoder()
        return data
            .split(separator: 0x0A)
            .compactMap { try? decoder.decode(AppLogEvent.self, from: Data($0)) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func rewrite(_ events: [AppLogEvent]) throws {
        var data = Data()
        let encoder = makeEncoder()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private func fileSize() -> UInt64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(max(0, values?.fileSize ?? 0))
    }

    private func eventsFittingFileLimit(_ events: [AppLogEvent]) -> [AppLogEvent] {
        let encoder = makeEncoder()
        let targetBytes = Int(maxFileBytes * 3 / 4)
        var byteCount = 0
        var retained: [AppLogEvent] = []

        for event in events.reversed() {
            guard let encoded = try? encoder.encode(event) else { continue }
            let nextByteCount = byteCount + encoded.count + 1
            if !retained.isEmpty, nextByteCount > targetBytes { break }
            retained.append(event)
            byteCount = nextByteCount
        }
        return Array(retained.reversed())
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func pruned(_ events: [AppLogEvent]) -> [AppLogEvent] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -maxAgeDays,
            to: Date()
        ) ?? .distantPast
        let recent = events
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
        return Array(recent.suffix(maxEntries))
    }
}
