import Testing
import Foundation
@testable import MacSweepCore

/// Exercises the partial-scan wire-through: a module that throws during a scan
/// must surface as a `HeadlessSummary.errors` entry (and, downstream, a nonzero
/// CLI exit) rather than masquerading as a smaller-but-complete result. Uses the
/// `init(engine:)` test seam to inject stub modules.
struct HeadlessServiceTests {
    struct ScanFailure: Error, LocalizedError {
        var errorDescription: String? { "stub module failed" }
    }

    /// A module whose scan() either throws or returns a fixed set of items.
    /// Defined locally because the equivalent stub in ScanEngineTests is nested
    /// and not reusable across files.
    struct StubModule: ScanModule {
        let id: String
        let name: String
        let description: String
        let icon: String = "testtube.2"
        let shouldThrow: Bool
        let itemsToReturn: [CleanupItem]

        func scan() async throws -> [CleanupItem] {
            if shouldThrow { throw ScanFailure() }
            return itemsToReturn
        }

        func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
            CleanupResult(itemsProcessed: 0, bytesFreed: 0)
        }
    }

    /// A temp-dir path resolves under /var/folders (a safe cache root), so the
    /// healthy module's item survives the scan-time safety filter.
    private func healthyItem() -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: FileManager.default.temporaryDirectory.appendingPathComponent("healthy.tmp"),
            size: 256,
            type: .file,
            module: "healthy",
            moduleName: "Healthy"
        )
    }

    @Test func partialScanSurfacesModuleFailureAsError() async throws {
        let item = healthyItem()
        let engine = ScanEngine(modules: [
            StubModule(id: "healthy", name: "Healthy", description: "Healthy",
                       shouldThrow: false, itemsToReturn: [item]),
            StubModule(id: "broken", name: "Broken", description: "Broken",
                       shouldThrow: true, itemsToReturn: []),
        ])
        let service = MacSweepHeadlessService(engine: engine)

        let result = try await service.scan(request: .init())

        // The healthy module's item is present...
        #expect(result.findings.contains { $0.module == "healthy" })
        // ...and the broken module is surfaced as a partial-scan error whose
        // `path` carries the failing module id.
        #expect(result.summary.errors.count == 1)
        #expect(result.summary.errors.first?.path == "broken")
    }

    @Test func completeScanHasNoErrors() async throws {
        let item = healthyItem()
        let engine = ScanEngine(modules: [
            StubModule(id: "healthy", name: "Healthy", description: "Healthy",
                       shouldThrow: false, itemsToReturn: [item]),
        ])
        let service = MacSweepHeadlessService(engine: engine)

        let result = try await service.scan(request: .init())

        #expect(result.summary.errors.isEmpty)
        #expect(result.findings.contains { $0.module == "healthy" })
    }
}
