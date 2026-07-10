import Testing
import Foundation
@testable import MacSweepCore

/// Boundary coverage for `DeletionGuard.preflightCheck`. The guard is the last
/// aggregate gate before any bulk delete, so its `>` (strictly-greater)
/// comparisons against the 1GB confirmation threshold and 10GB hard cap are
/// safety-critical: an off-by-one here would either nag on every tiny clean or
/// silently wave through an oversized batch. These tests pin the ACTUAL code
/// behavior (`>`, not `>=`), so the exact-threshold sizes resolve to the
/// lower-severity outcome.
struct DeletionGuardTests {
    private let guardUnit = DeletionGuard()

    private func item(size: Int64) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/tmp/macsweep-guard-fixture"),
            size: size,
            type: .file,
            module: "test",
            moduleName: "Test"
        )
    }

    private func dockerAction(size: Int64) -> CleanupItem {
        CleanupItem(id: UUID(), action: .docker(.pruneVolumes), size: size)
    }

    @Test func emptyBatchIsAllowed() {
        #expect(guardUnit.preflightCheck(items: []) == .allowed)
    }

    @Test func zeroSizedItemIsAllowed() {
        #expect(guardUnit.preflightCheck(items: [item(size: 0)]) == .allowed)
    }

    @Test func belowConfirmationThresholdIsAllowed() {
        // 512MB — comfortably under the 1GB confirmation threshold.
        #expect(guardUnit.preflightCheck(items: [item(size: 536_870_912)]) == .allowed)
    }

    @Test func exactlyOneGigabyteIsAllowed() {
        // 1GB == confirmationThreshold. The check uses `>`, so equality stays
        // .allowed — confirmation is only required ABOVE the threshold.
        #expect(guardUnit.preflightCheck(items: [item(size: 1_073_741_824)]) == .allowed)
    }

    @Test func oneByteOverThresholdRequiresConfirmation() {
        let total: Int64 = 1_073_741_825  // 1GB + 1
        #expect(guardUnit.preflightCheck(items: [item(size: total)]) == .requiresConfirmation(size: total))
    }

    @Test func midRangeRequiresConfirmation() {
        let total: Int64 = 5_368_709_120  // 5GB, between threshold and cap
        #expect(guardUnit.preflightCheck(items: [item(size: total)]) == .requiresConfirmation(size: total))
    }

    @Test func exactlyTenGigabytesRequiresConfirmation() {
        // 10GB == maxTotalSize. `totalSize > maxTotalSize` is false at equality,
        // so it falls through to the confirmation branch, not .blocked.
        let total: Int64 = 10_737_418_240
        #expect(guardUnit.preflightCheck(items: [item(size: total)]) == .requiresConfirmation(size: total))
    }

    @Test func oneByteOverCapIsBlocked() {
        let total: Int64 = 10_737_418_241  // 10GB + 1
        let result = guardUnit.preflightCheck(items: [item(size: total)])
        guard case .blocked = result else {
            Issue.record("Expected .blocked for size over the 10GB cap, got \(result)")
            return
        }
    }

    @Test func multipleItemsSumToCrossThreshold() {
        // Two 600MB items sum to 1.2GB > 1GB → confirmation. Verifies the guard
        // aggregates across items rather than checking each individually.
        let items = [item(size: 629_145_600), item(size: 629_145_600)]
        let total: Int64 = 1_258_291_200
        #expect(guardUnit.preflightCheck(items: items) == .requiresConfirmation(size: total))
    }

    @Test func dockerActionBytesCountTowardHardCap() {
        let items = [
            item(size: 5_368_709_120),
            dockerAction(size: 5_368_709_121),
        ]

        guard case .blocked = guardUnit.preflightCheck(items: items) else {
            Issue.record("Expected filesystem plus Docker action impact over 10GB to be blocked")
            return
        }
    }

    @Test func invalidNegativeImpactFailsClosed() {
        guard case .blocked = guardUnit.preflightCheck(items: [dockerAction(size: -1)]) else {
            Issue.record("Expected a negative declared impact to be blocked")
            return
        }
    }

    @Test func zeroSizedDockerActionFailsClosedAsUnverified() {
        guard case .blocked = guardUnit.preflightCheck(items: [dockerAction(size: 0)]) else {
            Issue.record("Expected an action with no verified impact to be blocked")
            return
        }
    }

    @Test func overflowingAggregateFailsClosed() {
        let items = [dockerAction(size: Int64.max), item(size: 1)]
        guard case .blocked = guardUnit.preflightCheck(items: items) else {
            Issue.record("Expected an overflowing impact aggregate to be blocked")
            return
        }
    }
}
