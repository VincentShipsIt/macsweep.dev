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

    private var smallGuard: DeletionGuard {
        DeletionGuard(
            maxTotalSize: 1_048_576,
            confirmationThreshold: 1_048_576,
            dryRunDefault: true
        )
    }

    private func item(
        at path: URL,
        size: Int64,
        type: CleanupItem.ItemType
    ) -> CleanupItem {
        CleanupItem(
            id: UUID(),
            path: path,
            size: size,
            type: type,
            module: "test",
            moduleName: "Test"
        )
    }

    @Test func emptyBatchIsAllowed() {
        #expect(guardUnit.preflightCheck(items: []) == .allowed)
    }

    @Test func zeroSizedItemIsAllowed() {
        #expect(guardUnit.classify(measuredTotalSize: 0) == .allowed)
    }

    @Test func belowConfirmationThresholdIsAllowed() {
        // 512MB — comfortably under the 1GB confirmation threshold.
        #expect(guardUnit.classify(measuredTotalSize: 536_870_912) == .allowed)
    }

    @Test func exactlyOneGigabyteIsAllowed() {
        // 1GB == confirmationThreshold. The check uses `>`, so equality stays
        // .allowed — confirmation is only required ABOVE the threshold.
        #expect(guardUnit.classify(measuredTotalSize: 1_073_741_824) == .allowed)
    }

    @Test func oneByteOverThresholdRequiresConfirmation() {
        let total: Int64 = 1_073_741_825  // 1GB + 1
        #expect(guardUnit.classify(measuredTotalSize: total) == .requiresConfirmation(size: total))
    }

    @Test func midRangeRequiresConfirmation() {
        let total: Int64 = 5_368_709_120  // 5GB, between threshold and cap
        #expect(guardUnit.classify(measuredTotalSize: total) == .requiresConfirmation(size: total))
    }

    @Test func exactlyTenGigabytesRequiresConfirmation() {
        // 10GB == maxTotalSize. `totalSize > maxTotalSize` is false at equality,
        // so it falls through to the confirmation branch, not .blocked.
        let total: Int64 = 10_737_418_240
        #expect(guardUnit.classify(measuredTotalSize: total) == .requiresConfirmation(size: total))
    }

    @Test func oneByteOverCapIsBlocked() {
        let total: Int64 = 10_737_418_241  // 10GB + 1
        let result = guardUnit.classify(measuredTotalSize: total)
        guard case .blocked = result else {
            Issue.record("Expected .blocked for size over the 10GB cap, got \(result)")
            return
        }
    }

    @Test func multipleMeasuredItemsSumToCrossThreshold() throws {
        // Two 600MB items sum to 1.2GB > 1GB → confirmation. Verifies the guard
        // counter aggregates rather than checking each independently.
        let total = try LiveDeletionByteCounter.checkedTotal(
            of: [629_145_600, 629_145_600],
            limit: guardUnit.maxTotalSize
        )
        #expect(guardUnit.classify(measuredTotalSize: total) == .requiresConfirmation(size: total))
    }

    @Test func checkedAggregationRejectsIntegerOverflow() {
        #expect(throws: LiveDeletionByteCounter.MeasurementError.arithmeticOverflow) {
            try LiveDeletionByteCounter.checkedTotal(of: [Int64.max, 1], limit: Int64.max)
        }
    }

    // MARK: - Live filesystem sizing

    @Test func staleStoredSizeCannotHideOversizedLiveFile() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardStaleSize")
        let file = temp.appendingPathComponent("grown.cache")
        try Data(repeating: 0xA5, count: 2_097_152).write(to: file)

        let result = smallGuard.preflightCheck(items: [item(at: file, size: 0, type: .file)])

        guard case .blocked = result else {
            Issue.record("Expected the live 2 MB file to exceed the 1 MB cap, got \(result)")
            return
        }
    }

    @Test func hiddenDirectoryEntriesCountTowardLiveTotal() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardHidden")
        let directory = temp.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(repeating: 0x5A, count: 2_097_152)
            .write(to: directory.appendingPathComponent(".hidden-payload"))

        let result = smallGuard.preflightCheck(items: [item(at: directory, size: 0, type: .directory)])

        guard case .blocked = result else {
            Issue.record("Expected hidden bytes to exceed the cap, got \(result)")
            return
        }
    }

    @Test func directorySymlinkDoesNotCountOrTraverseItsTarget() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardSymlink")
        let selectedDirectory = temp.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: false)

        let outsideTarget = temp.appendingPathComponent("outside-target.bin")
        try Data(repeating: 0xC3, count: 2_097_152).write(to: outsideTarget)
        try FileManager.default.createSymbolicLink(
            at: selectedDirectory.appendingPathComponent("payload-link"),
            withDestinationURL: outsideTarget
        )

        #expect(
            smallGuard.preflightCheck(items: [
                item(at: selectedDirectory, size: 0, type: .directory),
            ]) == .allowed
        )
    }

    @Test func overlappingSelectedPathsAreCountedOnce() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardOverlap")
        let directory = temp.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let child = directory.appendingPathComponent("payload.bin")
        try Data(repeating: 0x7E, count: 700_000).write(to: child)

        let result = smallGuard.preflightCheck(items: [
            item(at: directory, size: 700_000, type: .directory),
            item(at: child, size: 700_000, type: .file),
        ])

        #expect(result == .allowed)
    }

    @Test func contentGrowthAfterScanIsMeasuredAtCleanupTime() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardGrowth")
        let file = temp.appendingPathComponent("growing.cache")
        try Data(repeating: 0x11, count: 262_144).write(to: file)
        let scannedItem = item(at: file, size: 262_144, type: .file)

        // The file grows after the scan created its CleanupItem but before the
        // destructive preflight runs.
        try Data(repeating: 0x22, count: 2_097_152).write(to: file)

        let result = smallGuard.preflightCheck(items: [scannedItem])
        guard case .blocked = result else {
            Issue.record("Expected post-scan growth to exceed the live cap, got \(result)")
            return
        }
    }

    @Test func alreadyMissingPathFailsClosedDeterministically() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardMissing")
        let missing = temp.appendingPathComponent("already-gone.cache")

        let result = smallGuard.preflightCheck(items: [
            item(at: missing, size: 0, type: .file),
        ])
        guard case .blocked = result else {
            Issue.record("Expected a missing live path to fail closed, got \(result)")
            return
        }
    }

    @Test func unreadableDirectoryFailsClosed() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardUnreadable")
        let directory = temp.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: directory.appendingPathComponent("payload.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let result = smallGuard.preflightCheck(items: [item(at: directory, size: 0, type: .directory)])
        guard case .blocked = result else {
            Issue.record("Expected an unmeasurable directory to fail closed, got \(result)")
            return
        }
    }
}
