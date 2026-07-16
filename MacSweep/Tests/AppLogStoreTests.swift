import Foundation
import Testing
@testable import MacSweepCore

final class AppLogStoreTests {
    private let temp: TempTestDirectory
    private let logURL: URL

    init() throws {
        temp = try TempTestDirectory(prefix: "MacSweepAppLogTests")
        logURL = temp.appendingPathComponent("Logs/app-log.ndjson")
    }

    private func store(maxEntries: Int = 5_000) -> AppLogStore {
        AppLogStore(
            fileURL: logURL,
            maxEntries: maxEntries,
            maxAgeDays: 180,
            maxFileBytes: 1_024
        )
    }

    private var now: Date {
        Date()
    }

    @Test func persistsStructuredDeletionEventsAcrossStoreInstances() throws {
        let event = AppLogEvent(
            timestamp: now,
            category: .deletion,
            level: .error,
            message: "Move to Trash failed",
            module: "dev-tools",
            path: "/tmp/project/.build",
            action: "trash",
            errorMessage: "Permission denied"
        )

        store().record(event)

        let reloaded = try #require(store().events.first)
        #expect(reloaded == event)
        #expect(reloaded.searchableText.contains("dev-tools"))
        #expect(reloaded.searchableText.contains("Permission denied"))
    }

    @Test func ignoresMalformedLinesWithoutHidingValidEvents() throws {
        let first = AppLogEvent(
            timestamp: now,
            category: .scan,
            level: .error,
            message: "First valid event"
        )
        let second = AppLogEvent(
            timestamp: now.addingTimeInterval(1),
            category: .process,
            level: .debug,
            message: "Second valid event"
        )
        let writer = store()
        writer.record(first)
        try FileHandle(forWritingTo: logURL).closeAfterAppending(Data("not-json\n".utf8))
        writer.record(second)

        #expect(store().events == [first, second])
    }

    @Test func prunesOldAndExcessEventsFromReads() {
        let writer = store(maxEntries: 2)
        writer.record(AppLogEvent(
            timestamp: Date(timeIntervalSinceNow: -200 * 24 * 60 * 60),
            category: .scan,
            level: .debug,
            message: "Expired"
        ))
        let base = now
        let recent = (0..<3).map { index in
            AppLogEvent(
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                category: .deletion,
                level: .notice,
                message: "Recent \(index)"
            )
        }
        for event in recent { writer.record(event) }

        #expect(writer.events == Array(recent.suffix(2)))
    }

    @Test func clearRemovesEventsAndAuditFile() {
        let writer = store()
        writer.record(AppLogEvent(
            category: .deletion,
            level: .notice,
            message: "Deleted permanently"
        ))
        #expect(FileManager.default.fileExists(atPath: logURL.path))

        writer.clear()

        #expect(writer.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test func rotatesGrowingAuditFileUsingFreshOnDiskSize() throws {
        let writer = store()
        let payload = String(repeating: "x", count: 320)

        for index in 0..<20 {
            writer.record(AppLogEvent(
                timestamp: now.addingTimeInterval(TimeInterval(index)),
                category: .deletion,
                level: .notice,
                message: "Deletion \(index): \(payload)"
            ))
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let fileSize = try #require((attributes[.size] as? NSNumber)?.uint64Value)
        #expect(fileSize <= 1_024)
        #expect(writer.events.count < 20)
        #expect(writer.events.last?.message.hasPrefix("Deletion 19:") == true)
    }

    @Test func preservesSubsecondTimestampsAndOrdersTimestampTiesByID() throws {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000.123_456)
        let first = AppLogEvent(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            timestamp: timestamp,
            category: .scan,
            level: .notice,
            message: "First"
        )
        let second = AppLogEvent(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            timestamp: timestamp,
            category: .scan,
            level: .notice,
            message: "Second"
        )
        let later = AppLogEvent(
            timestamp: timestamp.addingTimeInterval(0.25),
            category: .scan,
            level: .notice,
            message: "Later"
        )
        let writer = store()
        writer.record(second)
        writer.record(later)
        writer.record(first)

        #expect(store().events == [first, second, later])
    }
}

private extension FileHandle {
    func closeAfterAppending(_ data: Data) throws {
        defer { try? close() }
        try seekToEnd()
        try write(contentsOf: data)
    }
}
