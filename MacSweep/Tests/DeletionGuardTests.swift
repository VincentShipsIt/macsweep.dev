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
    private final class TriggeredMutationFileManager: FileManager, @unchecked Sendable {
        let triggerDirectory: URL
        let mutation: () throws -> Void
        private(set) var didMutate = false

        init(triggerDirectory: URL, mutation: @escaping () throws -> Void) {
            self.triggerDirectory = triggerDirectory.standardizedFileURL
            self.mutation = mutation
            super.init()
        }

        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions
        ) throws -> [URL] {
            let contents = try super.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: mask
            )

            if !didMutate && url.standardizedFileURL == triggerDirectory {
                didMutate = true
                try mutation()
            }

            return contents
        }
    }

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

    private func dockerAction(size: Int64) -> CleanupItem {
        CleanupItem(id: UUID(), action: .docker(.pruneVolumes), size: size)
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

    @Test func dockerActionBytesCountTowardHardCap() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardMixedImpact")
        let file = temp.appendingPathComponent("payload.cache")
        try Data([0xA5]).write(to: file)
        let items = [
            item(at: file, size: 0, type: .file),
            dockerAction(size: guardUnit.maxTotalSize),
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
        let items = [dockerAction(size: Int64.max), dockerAction(size: 1)]
        guard case .blocked = guardUnit.preflightCheck(items: items) else {
            Issue.record("Expected an overflowing impact aggregate to be blocked")
            return
        }
    }

    @Test func hardLinkedSelectionsCountTheirAllocatedBytesOnce() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardHardLinks")
        let original = temp.appendingPathComponent("original.cache")
        let hardLink = temp.appendingPathComponent("alias.cache")
        try Data(repeating: 0xD3, count: 700_000).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLink)

        let result = smallGuard.preflightCheck(items: [
            item(at: original, size: 0, type: .file),
            item(at: hardLink, size: 0, type: .file),
        ])

        #expect(result == .allowed)
    }

    @Test func leafMutationLaterInTraversalIsRejected() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardLeafRace")
        let leaf = temp.appendingPathComponent("a-victim.bin")
        try Data(repeating: 0x6D, count: 65_536).write(to: leaf)
        let trigger = temp.appendingPathComponent("z-trigger")
        try FileManager.default.createDirectory(at: trigger, withIntermediateDirectories: false)

        let fileManager = TriggeredMutationFileManager(triggerDirectory: trigger) {
            let handle = try FileHandle(forWritingTo: leaf)
            defer { try? handle.close() }
            // In-place growth changes the leaf metadata without changing its
            // parent's directory mtime/ctime.
            try handle.truncate(atOffset: 2_097_152)
        }
        let counter = LiveDeletionByteCounter(fileManager: fileManager)

        do {
            _ = try counter.totalAllocatedBytes(for: [temp.url], limit: 8_388_608)
            Issue.record("Expected a leaf changed after accounting to invalidate the live snapshot")
        } catch LiveDeletionByteCounter.MeasurementError.changedDuringMeasurement(let path) {
            #expect(
                URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    == leaf.resolvingSymlinksInPath()
            )
        } catch let error as LiveDeletionByteCounter.MeasurementError {
            Issue.record("Expected a changed-node measurement error, got \(error)")
        } catch {
            Issue.record("Expected a measurement race error, got \(error)")
        }

        #expect(fileManager.didMutate)
    }

    @Test func guardBlocksLeafMutationLaterInTraversal() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardLeafRaceGate")
        let leaf = temp.appendingPathComponent("a-victim.bin")
        try Data(repeating: 0x4F, count: 65_536).write(to: leaf)
        let trigger = temp.appendingPathComponent("z-trigger")
        try FileManager.default.createDirectory(at: trigger, withIntermediateDirectories: false)

        let fileManager = TriggeredMutationFileManager(triggerDirectory: trigger) {
            let handle = try FileHandle(forWritingTo: leaf)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 2_097_152)
        }
        let result = DeletionGuard(
            maxTotalSize: 8_388_608,
            confirmationThreshold: 8_388_608,
            dryRunDefault: true
        ).preflightCheck(
            items: [item(at: temp.url, size: 0, type: .directory)],
            fileManager: fileManager
        )

        guard case .blocked(let reason) = result else {
            Issue.record("Expected DeletionGuard to block the raced leaf snapshot, got \(result)")
            return
        }
        #expect(reason.contains("Unable to safely measure"))
        #expect(fileManager.didMutate)
    }

    @Test func earlierDirectoryMutationDuringLaterSiblingTraversalIsRejected() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardDirectoryRace")
        let victim = temp.appendingPathComponent("a-victim-directory")
        let trigger = temp.appendingPathComponent("z-trigger")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: trigger, withIntermediateDirectories: false)

        let fileManager = TriggeredMutationFileManager(triggerDirectory: trigger) {
            try Data(repeating: 0x9A, count: 2_097_152)
                .write(to: victim.appendingPathComponent("late.cache"))
        }

        do {
            _ = try LiveDeletionByteCounter(fileManager: fileManager)
                .totalAllocatedBytes(for: [temp.url], limit: 8_388_608)
            Issue.record("Expected a previously walked directory mutation to invalidate the snapshot")
        } catch LiveDeletionByteCounter.MeasurementError.changedDuringMeasurement(let path) {
            #expect(
                URL(fileURLWithPath: path).resolvingSymlinksInPath()
                    == victim.resolvingSymlinksInPath()
            )
        } catch {
            Issue.record("Expected a directory measurement race error, got \(error)")
        }

        #expect(fileManager.didMutate)
    }

    @Test func deduplicatedHardLinkAliasReplacementIsRejected() throws {
        let temp = try TempTestDirectory(prefix: "DeletionGuardHardLinkRace")
        let original = temp.appendingPathComponent("a-original.cache")
        let alias = temp.appendingPathComponent("b-alias.cache")
        let trigger = temp.appendingPathComponent("z-trigger")
        try Data(repeating: 0x3C, count: 65_536).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)
        try FileManager.default.createDirectory(at: trigger, withIntermediateDirectories: false)

        let fileManager = TriggeredMutationFileManager(triggerDirectory: trigger) {
            try FileManager.default.removeItem(at: alias)
            try Data(repeating: 0xA7, count: 2_097_152).write(to: alias)
        }

        do {
            _ = try LiveDeletionByteCounter(fileManager: fileManager).totalAllocatedBytes(
                for: [original, alias, trigger],
                limit: 8_388_608
            )
            Issue.record("Expected replacement of a deduplicated hard-link alias to be rejected")
        } catch LiveDeletionByteCounter.MeasurementError.changedDuringMeasurement(let path) {
            let changed = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            // Unlinking the alias can update the shared inode's ctime/link
            // metadata, so either name may be the first snapshot to detect it.
            #expect([original, alias].map { $0.resolvingSymlinksInPath() }.contains(changed))
        } catch {
            Issue.record("Expected a hard-link alias measurement race error, got \(error)")
        }

        #expect(fileManager.didMutate)
    }
}
