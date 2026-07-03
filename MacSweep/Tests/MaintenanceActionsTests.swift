import Foundation
import Testing
@testable import MacSweepCore

/// Coverage for the `MaintenanceActions` error/result contract that issue #88
/// depends on: `OptimizationView.freeUpRAM()` now routes through
/// `MaintenanceActions.freeUpRAM()` and surfaces thrown errors instead of
/// silently swallowing them. These tests pin the surfaced shape (they do not
/// drive the real `/usr/sbin/purge` binary, whose success/failure is admin-gated
/// and non-deterministic in CI).
struct MaintenanceActionsTests {

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

    @Test func formattedBytesFreedUsesFileCountStyle() {
        let result = MaintenanceResult(success: true, message: "ok", bytesFreed: 1_000_000)
        let expected = ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .file)
        #expect(result.formattedBytesFreed == expected)
    }
}
