import Foundation
import Testing

@testable import MacSweepCore

struct UpdateSafetyTests {
    @Test func allSourcesAreGroupedWithCurrentAndLatest() async throws {
        let fixture = try UpdateFixture()
        let inventory = try await fixture.scanner(administrator: true).scan()
        #expect(inventory.reports.count == UpdateSource.allCases.count)
        #expect(Set(inventory.packages.map(\.source)) == Set(UpdateSource.allCases))
        #expect(inventory.packages.allSatisfy { $0.version.current == "1.0.0" && $0.version.latest == "2.0.0" })
        #expect(inventory.packages.allSatisfy { $0.isEligible })
    }

    @Test func missingToolsProduceHintsWithoutErrorsOrCommands() async throws {
        var scanner = UpdateScanner()
        scanner.managerPath = { _ in nil }
        scanner.commandRunner = { _, _ in throw DevArtifactSafetyError("should not run") }
        let inventory = try await scanner.scan()
        #expect(inventory.packages.isEmpty)
        #expect(inventory.reports.count == 7)
        #expect(inventory.reports.allSatisfy { !$0.isError && $0.message.contains("Install") })
    }

    @Test func administratorUnavailableIsVisibleBeforeStart() async throws {
        let fixture = try UpdateFixture()
        let inventory = try await fixture.scanner().scan(sources: [.mas])
        #expect(inventory.packages.count == 1)
        #expect(inventory.packages.first?.isEligible == false)
        #expect(inventory.packages.first?.blockedReason?.contains("App Store") == true)
    }

    @Test func unavailablePrivilegesRetainRows() async throws {
        let fixture = try UpdateFixture()
        var scanner = fixture.scanner()
        scanner.writableReason = { _ in "fixture read-only install" }
        let inventory = try await scanner.scan(sources: [.npm, .gem])
        #expect(inventory.packages.count == 3)
        #expect(inventory.packages.allSatisfy { !$0.isEligible && $0.blockedReason != nil })
    }

    @Test func oldHomebrewWithoutNoSudoCannotStart() async throws {
        let fixture = try UpdateFixture()
        var scanner = fixture.scanner()
        scanner.homebrewNoSudo = { _ in false }
        let inventory = try await scanner.scan(sources: [.brewFormula])
        #expect(inventory.packages.first?.isEligible == false)
    }

    @Test func pipxUnsupportedReadOnlyProbeIsAnHonestSourceFailure() async throws {
        let fixture = try UpdateFixture()
        await fixture.runner.failPipQuery()
        let inventory = try await fixture.scanner().scan(sources: [.pipx])
        #expect(inventory.packages.isEmpty)
        #expect(inventory.reports.first?.isError == true)
        #expect(inventory.reports.first?.message.contains("No updates were inferred") == true)
    }

    @Test func pinnedPipxApplicationRemainsVisibleAndLocked() async throws {
        let fixture = try UpdateFixture()
        await fixture.runner.pinPipx()
        let inventory = try await fixture.scanner().scan(sources: [.pipx])
        #expect(inventory.packages.count == 1)
        #expect(inventory.packages.first?.blockedReason?.contains("Pinned") == true)
        #expect(inventory.packages.first?.isEligible == false)
    }

    @Test func redirectedInstallRootIsRejected() throws {
        let fixture = try UpdateFixture()
        let link = fixture.root.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: fixture.root.appendingPathComponent("install"))
        #expect(UpdateProtection.writableReason([link]) != nil)
    }
}
