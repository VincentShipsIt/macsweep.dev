import Foundation
import Testing

@testable import MacSweepCore

struct UpdateExecutorTests {
    @Test func failuresContinueAndNativeOutputStreams() async throws {
        let fixture = try UpdateFixture()
        let scanner = fixture.scanner()
        let inventory = try await scanner.scan(sources: [.npm])
        await fixture.runner.fail("bar")
        let output = UpdateOutputReceipt()
        let outcomes = await fixture.executor().upgrade(inventory.packages) { _, bytes in output.append(bytes) }
        #expect(outcomes.count == 2)
        #expect(outcomes.filter(\.succeeded).count == 1)
        #expect(outcomes.filter { !$0.succeeded }.count == 1)
        #expect(await fixture.runner.updates.count == 2)
        #expect(output.text.contains("fixture streamed output"))
    }

    @Test func changedTargetVersionRequiresNewReview() async throws {
        let fixture = try UpdateFixture()
        let inventory = try await fixture.scanner().scan(sources: [.npm])
        await fixture.runner.setLatest("3.0.0")
        let outcomes = await fixture.executor().upgrade(inventory.packages) { _, _ in }
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(await fixture.runner.updates.isEmpty)
    }

    @Test func replacedExecutableCannotDispatch() async throws {
        let fixture = try UpdateFixture()
        let inventory = try await fixture.scanner().scan(sources: [.npm])
        try Data("replaced executable".utf8).write(to: URL(fileURLWithPath: try #require(fixture.tools["npm"])))
        let outcomes = await fixture.executor().upgrade(inventory.packages) { _, _ in }
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(await fixture.runner.updates.isEmpty)
    }

    @Test func rootReplacementRequiresNewReview() async throws {
        let fixture = try UpdateFixture()
        let inventory = try await fixture.scanner().scan(sources: [.gem])
        let root = fixture.root.appendingPathComponent("install/gems")
        try FileManager.default.moveItem(at: root, to: fixture.root.appendingPathComponent("old-gems"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outcomes = await fixture.executor().upgrade(inventory.packages) { _, _ in }
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(await fixture.runner.updates.isEmpty)
    }

    @Test func masRequiresBothUpfrontAcknowledgements() async throws {
        let fixture = try UpdateFixture()
        let runner = fixture.runner
        let admin: MasAdministratorUpdate = { request, output in await runner.administrator(request, output: output) }
        let inventory = try await fixture.scanner(administrator: true).scan(sources: [.mas])
        let executor = fixture.executor(administrator: admin)
        for acknowledgement in [UpdateAcknowledgements(), .init(administrator: true), .init(appStoreSignedIn: true)] {
            let outcomes = await executor.upgrade(inventory.packages, acknowledgements: acknowledgement) { _, _ in }
            #expect(outcomes.first?.succeeded == false)
        }
        #expect(await runner.administratorRequests.isEmpty)
        let completed = await executor.upgrade(
            inventory.packages,
            acknowledgements: .init(administrator: true, appStoreSignedIn: true)
        ) { _, _ in }
        #expect(completed.first?.succeeded == true)
        #expect(await runner.administratorRequests.first?.appID == 12345)
        #expect(await runner.updates.isEmpty)
    }

    @Test func invalidNamesNeverReachNativeUpgrade() async throws {
        let fixture = try UpdateFixture()
        await fixture.runner.setLatest("2.0.0;touch-file")
        let inventory = try await fixture.scanner().scan(sources: [.npm])
        #expect(inventory.packages.allSatisfy { !$0.isEligible })
        let outcomes = await fixture.executor().upgrade(inventory.packages) { _, _ in }
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(await fixture.runner.updates.isEmpty)
    }
}

private final class UpdateOutputReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data)
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: bytes, encoding: .utf8) ?? ""
    }
}
