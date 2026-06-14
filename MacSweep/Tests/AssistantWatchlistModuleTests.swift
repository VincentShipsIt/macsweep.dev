import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for the assistant watchlist scan path. The assistant can be steered
/// (via a model plan) toward arbitrary user-supplied directories, so the
/// per-child `SafetyChecker` gate is the only thing standing between it and a
/// sensitive path like `~/.ssh`. These tests assert both the gate's verdicts
/// directly (path-based, no filesystem dependency) and the module's end-to-end
/// scan behavior against real fixtures.
final class AssistantWatchlistModuleTests {
    private let tempDir: URL
    private let checker = SafetyChecker()
    private let moduleID = AssistantWatchlistModule.moduleID

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepWatchlistTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func home(_ relative: String) -> URL {
        URL(fileURLWithPath: (("~/" + relative) as NSString).expandingTildeInPath)
    }

    // MARK: - Gate verdicts (the safety-critical assertions)

    @Test func gateRejectsSSHDirectory() {
        // ~/.ssh is not under any safe-cache/allow root for this module, so the
        // default-deny gate must refuse it.
        #expect(checker.validateForScan(home(".ssh"), moduleID: moduleID).isSafe == false)
    }

    @Test func gateRejectsPrivateKeyByName() {
        // id_rsa matches the sensitive-filename patterns → always blocked,
        // regardless of location.
        #expect(checker.validateForScan(home(".ssh/id_rsa"), moduleID: moduleID).isSafe == false)
    }

    @Test func gateAllowsCachesDirectory() {
        // ~/Library/Caches is a safe-cache root → allowed even for this
        // all-false module profile.
        #expect(checker.validateForScan(home("Library/Caches/com.example.app"), moduleID: moduleID).isSafe == true)
    }

    // MARK: - Module scan

    @Test func scanReturnsItemsForLegitimateTarget() async throws {
        // A >1KB file inside a temp dir (which lives under /var/folders and is
        // therefore inside a safe-cache root) passes the gate and is reported.
        let file = tempDir.appendingPathComponent("payload.bin")
        try Data(count: 2048).write(to: file)

        let target = AssistantScanTarget(
            path: tempDir.path,
            label: "Temp Target",
            sourceRuleID: nil,
            excludePaths: []
        )
        let module = AssistantWatchlistModule(targets: [target])
        let items = try await module.scan()
        #expect(items.contains { $0.path.lastPathComponent == "payload.bin" })
    }

    @Test func scanReturnsNothingForMissingTarget() async throws {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let target = AssistantScanTarget(
            path: missing.path,
            label: "Missing",
            sourceRuleID: nil,
            excludePaths: []
        )
        let module = AssistantWatchlistModule(targets: [target])
        #expect(try await module.scan().isEmpty)
    }

    @Test func scanRefusesSSHTarget() async throws {
        // Even if a plan points the watchlist at ~/.ssh, the per-item gate keeps
        // every child out → empty result.
        let target = AssistantScanTarget(
            path: home(".ssh").path,
            label: "SSH",
            sourceRuleID: nil,
            excludePaths: []
        )
        let module = AssistantWatchlistModule(targets: [target])
        #expect(try await module.scan().isEmpty)
    }
}
