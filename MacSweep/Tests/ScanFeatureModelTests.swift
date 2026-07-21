import Foundation
import Testing
@testable import MacSweepCore

@MainActor
struct ScanFeatureModelTests {
    private enum SampleError: Error {
        case failed
    }

    private func item(id: UUID, name: String, size: Int64 = 1_024) -> CleanupItem {
        CleanupItem(
            id: id,
            path: URL(fileURLWithPath: "/tmp/\(name)"),
            size: size,
            type: .file,
            module: "test",
            moduleName: "Test"
        )
    }

    @Test func initializersPreserveEveryProjectedScanPhase() throws {
        let finding = item(
            id: try #require(UUID(uuidString: "4EE06A10-D307-4434-82B7-ABF205EB359A")),
            name: "finding"
        )

        let initial = ScanFeatureModel()
        let results = ScanFeatureModel(items: [finding], hasScanned: true)
        let empty = ScanFeatureModel(items: [], hasScanned: true)
        let failed = ScanFeatureModel(items: [], hasScanned: true, errorMessage: "failed")

        #expect(initial.scanPhase == .landing)
        #expect(!initial.isScanning)
        #expect(!initial.hasScanned)
        #expect(initial.items.isEmpty)
        #expect(initial.selectedItems.isEmpty)
        #expect(!initial.showingConfirmation)
        #expect(initial.errorMessage == nil)
        #expect(results.scanPhase == .results)
        #expect(empty.scanPhase == .empty)
        #expect(failed.scanPhase == .landing)
    }

    @Test func selectionOperationsUseTheProvidedProjection() throws {
        let first = item(
            id: try #require(UUID(uuidString: "8093FDD8-A3DB-4F95-8887-CA9FB776710F")),
            name: "first"
        )
        let second = item(
            id: try #require(UUID(uuidString: "13818625-6EC4-491F-9AB9-68E314208F35")),
            name: "second"
        )
        let model = ScanFeatureModel(items: [first, second], selectedItems: [first.id])

        model.selectAll([second])

        #expect(model.selectedItems == [second.id])

        model.deselectAll()

        #expect(model.selectedItems.isEmpty)
    }

    @Test func successfulScanReplacesResultsAndSelectsThemByDefault() async throws {
        let finding = item(
            id: try #require(UUID(uuidString: "A21A409D-FFB0-4F54-9122-64548934633E")),
            name: "successful"
        )
        let model = ScanFeatureModel(
            items: [],
            selectedItems: [],
            hasScanned: true,
            errorMessage: "stale failure"
        )

        await model.scan { [finding] }

        #expect(!model.isScanning)
        #expect(model.hasScanned)
        #expect(model.items == [finding])
        #expect(model.selectedItems == [finding.id])
        #expect(model.errorMessage == nil)
        #expect(model.scanPhase == .results)
    }

    @Test func failedScanMapsTheErrorAndLeavesAnEmptySelection() async {
        let model = ScanFeatureModel()

        await model.scan(onError: { _ in "Scan failed" }, {
            throw SampleError.failed
        })

        #expect(!model.isScanning)
        #expect(model.hasScanned)
        #expect(model.items.isEmpty)
        #expect(model.selectedItems.isEmpty)
        #expect(model.errorMessage == "Scan failed")
        #expect(model.scanPhase == .landing)
    }

    @Test func newerScanSupersedesAnInFlightResult() async throws {
        let stale = item(
            id: try #require(UUID(uuidString: "224B7F55-B47F-41D1-B082-C9B8392BA6DE")),
            name: "stale"
        )
        let current = item(
            id: try #require(UUID(uuidString: "D03B5BE4-11B9-443B-BE7C-5B8CA3608EF7")),
            name: "current"
        )
        let model = ScanFeatureModel()
        let firstScan = Task { @MainActor in
            await model.scan {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return [stale]
            }
        }

        while !model.isScanning {
            await Task.yield()
        }

        await model.scan { [current] }
        await firstScan.value

        #expect(!model.isScanning)
        #expect(model.hasScanned)
        #expect(model.items == [current])
        #expect(model.selectedItems == [current.id])
        #expect(model.isCurrent(model.activeScanToken))
    }

    @Test func cleanupRemovesSuccessesAndRetainsFailedItems() async throws {
        let removed = item(
            id: try #require(UUID(uuidString: "B2A74FBF-816C-4A7A-A745-F225164096D9")),
            name: "removed",
            size: 2_048
        )
        let blocked = item(
            id: try #require(UUID(uuidString: "9F7D8324-CBB1-4154-A4EE-89A955FDCA8F")),
            name: "blocked",
            size: 4_096
        )
        let untouched = item(
            id: try #require(UUID(uuidString: "12770550-93C1-470C-A740-349E2616421E")),
            name: "untouched",
            size: 8_192
        )
        let result = CleanupResult(
            itemsProcessed: 1,
            bytesFreed: removed.size,
            errors: [CleanupError(path: blocked.path, message: "Protected by policy")]
        )
        let model = ScanFeatureModel(cleanupOperation: { submitted in
            #expect(submitted == [removed, blocked])
            return result
        })
        model.items = [removed, blocked, untouched]
        model.selectedItems = [removed.id, blocked.id, untouched.id]

        let returned = await model.clean([removed, blocked]) { _ in "Unexpected failure" }

        #expect(returned?.itemsProcessed == 1)
        #expect(returned?.bytesFreed == removed.size)
        #expect(model.items == [blocked, untouched])
        #expect(model.selectedItems == [blocked.id, untouched.id])
        #expect(model.errorMessage == "1 item couldn't be removed: Protected by policy")
    }

    @Test func cleanupThrowPreservesStateAndUsesTheFailureMapper() async throws {
        let finding = item(
            id: try #require(UUID(uuidString: "70A7E574-8DD2-482A-8EF3-F6F0CF4C5F7F")),
            name: "retained"
        )
        let model = ScanFeatureModel(cleanupOperation: { _ in
            throw SampleError.failed
        })
        model.items = [finding]
        model.selectedItems = [finding.id]

        let result = await model.clean([finding]) { _ in "Cleanup failed" }

        #expect(result == nil)
        #expect(model.items == [finding])
        #expect(model.selectedItems == [finding.id])
        #expect(model.errorMessage == "Cleanup failed")
    }
}
