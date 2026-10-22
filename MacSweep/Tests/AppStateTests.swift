import Foundation
import Testing

@testable import MacSweepCore

@MainActor
struct AppStateTests {
    private func model(
        hasAccess: Bool = true, modules: [any ScanModule] = [],
        cleanup: (([CleanupItem], Bool, Bool) async throws -> CleanupResult)? = nil
    ) -> AppState {
        let defaults = UserDefaults(suiteName: "AppStateTests.\(UUID())")!
        return AppState(
            initialFullDiskAccess: hasAccess, scanEngine: ScanEngine(modules: modules),
            assistant: AssistantCoordinator(automaticallyReload: false),
            cleanupPerformanceStore: CleanupPerformanceStore(defaults: defaults),
            diskUsageProvider: { nil }, cleanupOperation: cleanup)
    }

    private func item(_ name: String, size: Int64 = 1_024) -> CleanupItem {
        CleanupItem(
            id: UUID(), path: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            size: size, type: .file, module: "fixture", moduleName: "Fixture")
    }

    @Test func fullDiskAccessBlocksGlobalButPermitsScopedScan() async {
        let finding = item("scoped")
        let state = model(hasAccess: false, modules: [FixtureModule(items: [finding])])
        await state.quickScan()
        #expect(state.lastError == FullDiskAccessScope.smartCare.actionBlockedMessage)
        #expect(state.scanResults.isEmpty)
        await state.scan(modules: ["fixture"])
        #expect(state.lastError == nil)
        #expect(state.scanResults == [finding])
        #expect(state.selectedItems == [finding.id])
        #expect(!state.isScanning)
        #expect(state.currentScanModule == nil)
        #expect(state.scanProgress == 1)
        await state.retryLastScan()
        #expect(state.lastError == nil)
        #expect(state.scanResults == [finding])
    }

    @Test func partialScanKeepsHealthyFindingsAndRetryUsesSameScope() async {
        let finding = item("healthy")
        let state = model(modules: [
            FixtureModule(items: [finding]), FixtureModule(id: "broken", fails: true),
            FixtureModule(id: "excluded", items: [item("excluded")])
        ])
        await state.scan(modules: ["fixture", "broken"])
        #expect(state.scanResults == [finding])
        #expect(state.scanFailures.map(\.moduleID) == ["broken"])
        #expect(state.lastError == nil)
        await state.retryLastScan()
        #expect(state.scanResults == [finding])
        #expect(state.scanFailures.map(\.moduleID) == ["broken"])
    }

    @Test func selectionChangedDuringCleanupCannotRemoveUnsubmittedRows() async throws {
        let removed = item("removed")
        let untouched = item("untouched")
        var submitted = false
        var finish: CheckedContinuation<CleanupResult, Never>?
        let state = model(cleanup: { items, dryRun, confirmed in
            #expect(items == [removed])
            #expect(!dryRun && confirmed)
            submitted = true
            return await withCheckedContinuation { finish = $0 }
        })
        state.scanResults = [removed, untouched]
        state.selectedItems = [removed.id]
        let task = Task { try await state.deleteSelected(confirmedLargeDeletion: true) }
        for _ in 0..<1_000 where !submitted { await Task.yield() }
        #expect(submitted)
        state.selectedItems = [untouched.id]
        finish?.resume(returning: CleanupResult(itemsProcessed: 1, bytesFreed: removed.size))
        _ = try await task.value
        #expect(state.scanResults == [untouched])
        #expect(state.selectedItems == [untouched.id])
        #expect(state.lastCleanup?.itemsProcessed == 1)
        #expect(state.cleanupPerformanceHistory.count == 1)
    }

    @Test func partialCleanupRetainsFailuresAndDryRunDoesNotMutateState() async throws {
        let removed = item("success")
        let blocked = item("blocked")
        let result = CleanupResult(
            itemsProcessed: 1, bytesFreed: removed.size,
            errors: [CleanupError(path: blocked.path, message: "Protected")])
        let state = model(cleanup: { _, _, _ in result })
        state.scanResults = [removed, blocked]
        state.selectAll()
        _ = try await state.deleteSelected(dryRun: true)
        #expect(state.scanResults == [removed, blocked])
        #expect(state.lastCleanup == nil)
        #expect(state.cleanupPerformanceHistory.isEmpty)
        _ = try await state.deleteSelected()
        #expect(state.scanResults == [blocked])
        #expect(state.selectedItems == [blocked.id])
        #expect(state.lastDeletionError?.contains("Protected") == true)
    }

    @Test func thrownCleanupPreservesResultsAndSurfacesFailure() async {
        let finding = item("retained")
        let state = model(cleanup: { _, _, _ in throw ScanEngineError.deletionBlocked(reason: "Cap exceeded") })
        state.scanResults = [finding]
        state.selectedItems = [finding.id]
        do {
            _ = try await state.deleteSelected()
            Issue.record("Expected guard failure")
        } catch { #expect(state.lastDeletionError == "Cap exceeded") }
        #expect(state.scanResults == [finding])
        #expect(state.lastCleanup == nil)
    }

    @Test func activeCancellationDiscardsLateFindingsAndResetsProgressState() async {
        let gate = ScanGate()
        let state = model(modules: [FixtureModule(items: [item("late")], gate: gate)])
        let scan = Task { await state.scan(modules: ["fixture"]) }
        await gate.waitUntilStarted()
        #expect(state.isScanning)
        state.cancelScan()
        await gate.release()
        await scan.value
        #expect(!state.isScanning)
        #expect(state.currentScanModule == nil)
        #expect(state.scanResults.isEmpty)
        #expect(state.selectedItems.isEmpty)
        #expect(state.lastError == nil)
    }

    @Test func cancelledQueuedScanNeverReplacesActiveResults() async {
        let gate = ScanGate()
        let finding = item("first")
        let state = model(modules: [
            FixtureModule(items: [finding], gate: gate),
            FixtureModule(id: "queued", items: [item("must-not-run")])
        ])
        let first = Task { await state.scan(modules: ["fixture"]) }
        await gate.waitUntilStarted()
        let queued = Task { await state.scan(modules: ["queued"]) }
        await Task.yield()
        queued.cancel()
        await gate.release()
        await first.value
        await queued.value
        #expect(state.scanResults == [finding])
        #expect(!state.isScanning)
    }
}

private struct FixtureModule: ScanModule {
    var id = "fixture"
    var name: String { id }
    let description = "Test inventory"
    let icon = "testtube.2"
    var items: [CleanupItem] = []
    var fails = false
    var gate: ScanGate?
    func scan() async throws -> [CleanupItem] {
        if let gate { await gate.suspend() }
        if fails { throw CocoaError(.fileReadNoPermission) }
        return items
    }
    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        CleanupResult(itemsProcessed: 0, bytesFreed: 0)
    }
}

private actor ScanGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        for _ in 0..<3_000 where !started { try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(started)
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
