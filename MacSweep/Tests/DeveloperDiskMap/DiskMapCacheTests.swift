import Foundation
import Testing

@testable import MacSweepCore

struct DiskMapCacheTests {
    @Test func lowUnknownSpaceAndIncompleteCoverageNeverWriteAnIndex() async throws {
        let temporary = try TempTestDirectory(prefix: "DiskMapCache")
        let file = temporary.url.resolvingSymlinksInPath().appending(path: "index.json")
        let cache = DiskMapCache(file: file)
        let report = DiskMapReport(roots: [DiskMapNode(id: "fixture", name: "Fixture")], finished: true)
        let entry = DiskMapCache.Entry(key: "fixture", report: report, records: [:])
        #expect(!(await cache.put(entry, freeBytes: nil)))
        #expect(!(await cache.put(entry, freeBytes: 1)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        var partial = entry
        partial.report.roots[0].coverage = .partial
        #expect(!(await cache.put(partial, freeBytes: Int64.max)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await cache.get("fixture") != nil)
    }

    @Test func boundedIndexPersistsAndTTLExpiresWithoutAnUnboundedRead() async throws {
        let temporary = try TempTestDirectory(prefix: "DiskMapCache")
        let file = temporary.url.resolvingSymlinksInPath().appending(path: "index.json")
        let cache = DiskMapCache(file: file, ttl: 60)
        let report = DiskMapReport(roots: [DiskMapNode(id: "fixture", name: "Fixture")], finished: true)
        let entry = DiskMapCache.Entry(key: "fixture", report: report, records: [:])
        #expect(await cache.put(entry, freeBytes: Int64.max))
        #expect(try Data(contentsOf: file).count <= DiskMapCache.maximumIndexBytes)
        let reopened = DiskMapCache(file: file, ttl: 60)
        #expect(await reopened.get("fixture")?.report.roots.count == 1)
        #expect(await reopened.get("fixture", now: report.measuredAt.addingTimeInterval(61)) == nil)
        var oversized = entry
        oversized.report.roots[0].name = String(repeating: "x", count: DiskMapCache.maximumIndexBytes + 1)
        #expect(!(await cache.put(oversized, freeBytes: Int64.max)))
        try Data(count: DiskMapCache.maximumIndexBytes + 1).write(to: file)
        #expect(await DiskMapCache(file: file).get("fixture") == nil)
    }

    @Test func symlinkIndexCannotReadOrOverwriteAnotherFile() async throws {
        let temporary = try TempTestDirectory(prefix: "DiskMapCache")
        let base = temporary.url.resolvingSymlinksInPath()
        let target = base.appending(path: "retained")
        let original = Data("retained fixture".utf8)
        try original.write(to: target)
        let index = base.appending(path: "index.json")
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: target)
        let cache = DiskMapCache(file: index)
        #expect(await cache.get("fixture") == nil)
        let entry = DiskMapCache.Entry(key: "fixture", report: DiskMapReport(finished: true), records: [:])
        #expect(!(await cache.put(entry, freeBytes: Int64.max)))
        #expect(try Data(contentsOf: target) == original)
    }
}
