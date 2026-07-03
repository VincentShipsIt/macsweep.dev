import Testing
import Foundation
@testable import MacSweepCore

/// #91: the five formerly copy-pasted modules now route deletion through the
/// shared `cleanItems` + `CleanupFileRemover` path instead of raw `FileManager`.
/// These assert the observable end-to-end contract per module: a real clean
/// removes the source file and reports no error, and a missing file accumulates
/// an error while processing nothing (the shared error-accumulation path).
final class ModuleRemoverRoutingTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepRouting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ url: URL, module: String) -> CleanupItem {
        CleanupItem(id: UUID(), path: url, size: 1024, type: .file, module: module, moduleName: "test")
    }

    private func assertRealCleanRemovesSource(_ module: any ScanModule) async throws {
        let file = dir.appendingPathComponent("\(module.id)-victim.bin")
        try Data("bytes".utf8).write(to: file)

        let result = try await module.clean(items: [item(file, module: module.id)], dryRun: false)

        #expect(result.errors.isEmpty, "\(module.id): expected no errors")
        #expect(result.itemsProcessed == 1, "\(module.id): expected 1 processed")
        #expect(!FileManager.default.fileExists(atPath: file.path), "\(module.id): source should be gone")
    }

    private func assertMissingFileAccumulatesError(_ module: any ScanModule) async throws {
        let missing = dir.appendingPathComponent("\(module.id)-missing.bin")

        let result = try await module.clean(items: [item(missing, module: module.id)], dryRun: false)

        #expect(!result.errors.isEmpty, "\(module.id): missing file should accumulate an error")
        #expect(result.itemsProcessed == 0, "\(module.id): nothing should be processed")
    }

    @Test func duplicateFinderRoutesThroughRemover() async throws {
        try await assertRealCleanRemovesSource(DuplicateFinderModule())
        try await assertMissingFileAccumulatesError(DuplicateFinderModule())
    }

    @Test func largeFilesRoutesThroughRemover() async throws {
        try await assertRealCleanRemovesSource(LargeFilesModule())
        try await assertMissingFileAccumulatesError(LargeFilesModule())
    }

    @Test func mailAttachmentsRoutesThroughRemover() async throws {
        try await assertRealCleanRemovesSource(MailAttachmentsModule())
        try await assertMissingFileAccumulatesError(MailAttachmentsModule())
    }

    @Test func similarPhotosRoutesThroughRemover() async throws {
        try await assertRealCleanRemovesSource(SimilarPhotosModule())
        try await assertMissingFileAccumulatesError(SimilarPhotosModule())
    }
}
