import Foundation
import Testing

@testable import MacSweepCore

struct LocalSnapshotTests {
    @Test func listingParsesDatesAndDatalessButRejectsUnknownRecords() throws {
        let values = try LocalSnapshotParsing.snapshots(
            "Snapshots for disk /:\ncom.apple.TimeMachine.2026-01-02-030405.local (dataless)\n")
        #expect(values.count == 1)
        #expect(values.first?.dateToken == "2026-01-02-030405")
        #expect(values.first?.isDataless == true)
        #expect(try LocalSnapshotParsing.snapshots("Snapshots for disk /:\n").isEmpty)
        for output in ["", "Snapshots for disk /:\ncom.apple.os.update.fixture", "Snapshots for disk /:\n; rm -rf /"] {
            #expect(throws: (any Error).self) { try LocalSnapshotParsing.snapshots(output) }
        }
    }

    @Test func datesRejectInjectionInvalidCalendarsAndDuplicates() throws {
        for token in ["2026-02-30-030405", "2026-01-02-250405", "2026-01-02-030405;id", "-1", "all"] {
            #expect(throws: LocalSnapshotError.self) { try LocalSnapshotParsing.parseDate(token) }
        }
        let line = "com.apple.TimeMachine.2026-01-02-030405.local"
        #expect(throws: LocalSnapshotError.self) {
            try LocalSnapshotParsing.snapshots("Snapshots for disk /:\n\(line)\n\(line)")
        }
    }

    @Test func exactFiniteScriptsHaveNoScannedArguments() {
        #expect(
            LocalSnapshotThinningTarget.allCases.map(\.commandDescription) == [
                "/usr/bin/tmutil thinlocalsnapshots / 1073741824 1",
                "/usr/bin/tmutil thinlocalsnapshots / 5368709120 1",
                "/usr/bin/tmutil thinlocalsnapshots / 10737418240 1"
            ])
        #expect(
            !LocalSnapshotThinningTarget.allCases.contains { $0.commandDescription.contains("deletelocalsnapshots") })
    }

    @Test func scanAndThinReportObservedChangesWithoutClaimingCausalBytes() async throws {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        let inventory = await service.scan()
        #expect(inventory.canThin)
        let receipt = await service.thin(.oneGiB, reviewed: inventory, confirmed: true)
        #expect(receipt.commandCompleted)
        #expect(receipt.errors.isEmpty)
        #expect(receipt.observedMissingIDs.count == 2)
        #expect(receipt.observation?.observedAvailableChange == 1000)
        #expect(receipt.beforeReclaimable == 10_000)
        #expect(receipt.afterReclaimable == 7000)
        #expect(receipt.result.bytesFreed == 0)
        #expect(receipt.result.accounting?.volumeObservations.count == 1)
        #expect(fixture.adminCalls == [.oneGiB])
        #expect(!fixture.commandCalls.contains { $0.contains("thinlocalsnapshots") && !$0.contains("help") })
    }

    @Test func noSnapshotsAndMissingPermissionsBlockUpFront() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        fixture.update { $0.names = [] }
        #expect(await service.scan().canThin == false)
        fixture.update {
            $0.names = ["com.apple.TimeMachine.2026-01-02-030405.local"]
            $0.permissions = LocalSnapshotPermissions(hasFullDiskAccess: false, authorizationAvailable: true)
        }
        let inventory = await service.scan()
        #expect(!inventory.canThin)
        #expect(inventory.permissions.blocker?.contains("Full Disk Access") == true)
        let receipt = await service.thin(.oneGiB, reviewed: inventory, confirmed: true)
        #expect(!receipt.commandCompleted)
        #expect(fixture.adminCalls.isEmpty)
    }

    @Test func backupActivityAndMalformedInventoryBlockThinning() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        fixture.update { $0.running = true }
        #expect(await service.scan().canThin == false)
        fixture.update {
            $0.running = false
            $0.malformed = true
        }
        let inventory = await service.scan()
        #expect(!inventory.canThin)
        #expect(!inventory.issues.isEmpty)
    }

    @Test func changedSnapshotSetOrVolumeInvalidatesReview() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        let inventory = await service.scan()
        fixture.update { $0.names.append("com.apple.TimeMachine.2026-01-03-030405.local") }
        #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: true).commandCompleted == false)
        fixture.update {
            $0.names = inventory.snapshots.map(\.name)
            $0.volumeID = UUID().uuidString
        }
        #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: true).commandCompleted == false)
        #expect(fixture.adminCalls.isEmpty)
    }

    @Test func freshRulesAndPermissionRevocationPreventAuthorization() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        let inventory = await service.scan()
        fixture.update {
            $0.rules = UserProtectionRules(
                ignoreContents: "", protectContents: "/Volumes/com.apple.TimeMachine.localsnapshots",
                homeURL: URL(fileURLWithPath: "/Users/example"))
        }
        #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: true).commandCompleted == false)
        fixture.update {
            $0.rules = .empty
            $0.permissions = LocalSnapshotPermissions(hasFullDiskAccess: true, authorizationAvailable: false)
        }
        #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: true).commandCompleted == false)
        #expect(fixture.adminCalls.isEmpty)
    }

    @Test func guardAndConfirmationPreventAdministratorDispatch() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service(limit: 1)
        let inventory = await service.scan()
        #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: true).commandCompleted == false)
        #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: false).commandCompleted == false)
        #expect(fixture.adminCalls.isEmpty)
    }

    @Test func declinedAuthorizationAndUnverifiedAfterStateAreNotSuccess() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        let inventory = await service.scan()
        fixture.update { $0.failAdmin = true }
        let declined = await service.thin(.oneGiB, reviewed: inventory, confirmed: true)
        #expect(!declined.commandCompleted)
        #expect(!declined.errors.isEmpty)
        fixture.update {
            $0.failAdmin = false
            $0.failAfterAdmin = true
            $0.adminCalls = []
        }
        let uncertain = await service.thin(.oneGiB, reviewed: inventory, confirmed: true)
        #expect(uncertain.commandCompleted)
        #expect(!uncertain.errors.isEmpty)
        #expect(uncertain.observedMissingIDs.isEmpty)
    }

    @Test func unknownCapacityStaysUnavailableAndCrossVolumeDeltaIsRejected() {
        let snapshot = VolumeSpaceSnapshot(
            timestamp: Date(), volumeID: "a", volumePath: "/",
            availableBytes: nil, errorMessage: "unavailable")
        #expect(LocalSnapshotCapacity(available: snapshot, importantUsageBytes: 100).reclaimableEstimate == nil)
        let other = VolumeSpaceSnapshot(
            timestamp: Date(), volumeID: "b", volumePath: "/",
            availableBytes: 100, errorMessage: nil)
        #expect(VolumeSpaceObservation(before: snapshot, after: other).observedAvailableChange == nil)
    }
    @Test func hardCodedAdministratorScriptsParseWithoutExecuting() async throws {
        let fixture = try TempTestDirectory(prefix: "SnapshotSyntax")
        for target in LocalSnapshotThinningTarget.allCases {
            let script = fixture.url.appendingPathComponent("script.sh")
            try target.trustedScript.write(to: script, atomically: true, encoding: .utf8)
            let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-n", script.path], timeout: 5)
            #expect(result.didSucceed)
            #expect(target.trustedScript.hasSuffix(target.commandDescription))
        }
    }

    @Test func protectedVolumeAndExactSnapshotIntentPreventThinning() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        let inventory = await service.scan()
        for path in ["/", "/System/Volumes/Data", "/Volumes/com.apple.TimeMachine.localsnapshots/2026-01-02-030405"] {
            fixture.update {
                $0.rules = UserProtectionRules(
                    ignoreContents: "", protectContents: path,
                    homeURL: URL(fileURLWithPath: "/Users/example"))
            }
            #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: true).commandCompleted == false)
        }
        #expect(fixture.adminCalls.isEmpty)
    }

    @Test func nativeFailureAndUnknownBackupStatusDoNotAuthorize() async {
        let fixture = LocalSnapshotFixture()
        fixture.update { $0.failNative = true }
        let service = fixture.service()
        let inventory = await service.scan()
        #expect(!inventory.canThin)
        #expect(!inventory.issues.isEmpty)
        #expect(await service.thin(.oneGiB, reviewed: inventory, confirmed: true).commandCompleted == false)
        #expect(fixture.adminCalls.isEmpty)
        #expect(throws: (any Error).self) { try LocalSnapshotParsing.backupRunning("{ Running = unknown; }") }
        #expect(throws: (any Error).self) { try LocalSnapshotParsing.backupRunning("{ Running = 0.5; }") }
    }

    @Test func successfulExitWithNativeWarningDoesNotAuthorizeIncompleteInventory() async {
        let fixture = LocalSnapshotFixture()
        let service = fixture.service()
        let reviewed = await service.scan()
        #expect(reviewed.canThin)
        fixture.update { $0.nativeWarning = true }
        let inventory = await service.scan()
        #expect(!inventory.canThin)
        #expect(!inventory.issues.isEmpty)
        #expect(await service.thin(.oneGiB, reviewed: reviewed, confirmed: true).commandCompleted == false)
        #expect(fixture.adminCalls.isEmpty)
    }

}
