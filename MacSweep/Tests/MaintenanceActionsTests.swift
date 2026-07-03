import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for MaintenanceActions' deterministic seams. The actions themselves
/// spawn system tools (purge, mdutil, periodic) and mutate host state, so tests
/// cover the extracted vm_stat parsing, the error/result contract that
/// `OptimizationView.freeUpRAM()` surfaces (#88), result formatting, and the
/// CLI-facing task-table metadata (#120) instead of executing the actions.
struct MaintenanceActionsTests {

    // MARK: - vm_stat parsing

    @Test func parsesFreePagesIntoBytes() {
        let output = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                              12345.
        Pages active:                           999999.
        """
        #expect(MaintenanceActions.parseVMStatFreeBytes(output, pageSize: 16_384) == 12_345 * 16_384)
    }

    @Test func parsesWithIntelPageSize() {
        let output = "Pages free: 100.\n"
        #expect(MaintenanceActions.parseVMStatFreeBytes(output, pageSize: 4_096) == 409_600)
    }

    @Test func returnsZeroWhenMarkerMissing() {
        #expect(MaintenanceActions.parseVMStatFreeBytes("Pages active: 5.\n", pageSize: 4_096) == 0)
        #expect(MaintenanceActions.parseVMStatFreeBytes("", pageSize: 4_096) == 0)
    }

    @Test func returnsZeroForMalformedValue() {
        #expect(MaintenanceActions.parseVMStatFreeBytes("Pages free: not-a-number.\n", pageSize: 4_096) == 0)
    }

    // MARK: - Error/result contract (#88: freeUpRAM errors must surface)

    @Test func commandFailedDescribesCommandAndReason() {
        let error = MaintenanceError.commandFailed("purge", "Exit code: 1")
        #expect(error.errorDescription == "purge failed: Exit code: 1")
    }

    @Test func permissionDeniedMentionsAdminRequirement() {
        let error = MaintenanceError.permissionDenied("free RAM")
        #expect(error.errorDescription?.contains("free RAM") == true)
        #expect(error.errorDescription?.contains("Administrator") == true)
    }

    /// The exact failure result the GUI builds in its `catch` when
    /// `MaintenanceActions.freeUpRAM()` throws — the value that now reaches the
    /// user via the Optimization banner instead of a silent no-op.
    @Test func surfacedFailureResultCarriesMessage() {
        let error = MaintenanceError.commandFailed("purge", "not available")
        let result = MaintenanceResult(success: false, message: error.localizedDescription)
        #expect(result.success == false)
        #expect(result.message == "purge failed: not available")
        #expect(result.bytesFreed == 0)
    }

    // MARK: - Result formatting

    @Test func formattedBytesFreedUsesFileCountStyle() {
        let result = MaintenanceResult(success: true, message: "ok", bytesFreed: 1_000_000)
        let expected = ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .file)
        #expect(result.formattedBytesFreed == expected)
    }

    // MARK: - Task table metadata

    @Test func taskIDsAreUniqueAndComplete() {
        let ids = MaintenanceTask.allTasks.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate maintenance task id")
        // The CLI exposes these ids (`macsweep maintenance <action>`); renaming
        // one is a breaking interface change that must be deliberate.
        let expected: Set<String> = [
            "free-ram", "flush-dns", "rebuild-spotlight", "verify-disk",
            "free-purgeable", "maintenance-scripts", "clear-font-cache",
            "rebuild-launchservices",
        ]
        #expect(Set(ids) == expected)
    }

    @Test func adminFlagsMatchDocumentedRequirements() {
        let requiresAdmin = Dictionary(
            uniqueKeysWithValues: MaintenanceTask.allTasks.map { ($0.id, $0.requiresAdmin) }
        )
        #expect(requiresAdmin["rebuild-spotlight"] == true)
        #expect(requiresAdmin["maintenance-scripts"] == true)
        #expect(requiresAdmin["free-ram"] == false)
        #expect(requiresAdmin["flush-dns"] == false)
    }
}
