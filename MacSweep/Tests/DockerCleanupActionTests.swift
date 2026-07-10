import Foundation
import Testing
@testable import MacSweepCore

/// End-to-end contract tests for Docker findings as typed, non-filesystem
/// cleanup actions. The command recorder is the security boundary assertion:
/// item labels and filesystem paths must never become executable argv.
struct DockerCleanupActionTests {
    actor CommandRecorder {
        struct Invocation: Equatable {
            let executable: String
            let arguments: [String]
        }

        private var invocations: [Invocation] = []
        private let dockerDFOutput: String

        init(dockerDFOutput: String = "") {
            self.dockerDFOutput = dockerDFOutput
        }

        func run(executable: String, arguments: [String]) -> ProcessResult {
            invocations.append(Invocation(executable: executable, arguments: arguments))
            if arguments == ["system", "df", "--format", "{{json .}}"] {
                return ProcessResult(status: 0, output: dockerDFOutput, error: "")
            }
            return ProcessResult(
                status: 0,
                output: "Total reclaimed space: 64MB\n",
                error: ""
            )
        }

        func recordedInvocations() -> [Invocation] {
            invocations
        }
    }

    private func module(recorder: CommandRecorder) -> DockerModule {
        DockerModule(
            dockerPath: { "/test/bin/docker" },
            commandRunner: { executable, arguments in
                await recorder.run(executable: executable, arguments: arguments)
            }
        )
    }

    @Test func scanSurfacesTypedActionsWithCanonicalLabelsAndReclaimableBytes() async throws {
        let output = [
            #"{"Reclaimable":"256MB (100%)","Type":"Build Cache"}"#,
            #"{"Reclaimable":"1.5GB (75%)","Type":"Images"}"#,
            #"{"Reclaimable":"0B","Type":"Containers"}"#,
            #"{"Reclaimable":"32MB (100%)","Type":"Local Volumes"}"#,
        ].joined(separator: "\n")
        let recorder = CommandRecorder(dockerDFOutput: output)
        let engine = ScanEngine(modules: [module(recorder: recorder)])

        let items = try await engine.scan(modules: ["docker"])
        let actions = items.filter { $0.type == .action }

        #expect(actions.count == 3)
        #expect(actions.allSatisfy { !$0.path.isFileURL })
        #expect(actions.allSatisfy { $0.path.scheme == "macsweep-action" })
        #expect(actions.allSatisfy { $0.module == "docker" && $0.moduleName == $0.displayName })
        #expect(Dictionary(uniqueKeysWithValues: actions.map { ($0.displayName, $0.size) }) == [
            "Docker Build Cache": 268_435_456,
            "Docker Images": 1_610_612_736,
            "Docker Volumes": 33_554_432,
        ])

        let preview = try await engine.clean(items: actions, dryRun: true)
        #expect(preview.itemsProcessed == 3)
        #expect(preview.bytesFreed == 1_912_602_624)
    }

    @Test func everyTypedActionMapsToOneFixedAllowlistedCommand() async throws {
        let recorder = CommandRecorder()
        let docker = module(recorder: recorder)
        let items = DockerCleanupAction.allCases.map {
            CleanupItem(id: UUID(), action: .docker($0), size: 1)
        }

        let result = try await docker.clean(items: items, dryRun: false)
        let invocations = await recorder.recordedInvocations()

        #expect(result.itemsProcessed == DockerCleanupAction.allCases.count)
        #expect(invocations.map(\.executable) == Array(
            repeating: "/test/bin/docker",
            count: DockerCleanupAction.allCases.count
        ))
        #expect(invocations.map(\.arguments) == [
            ["builder", "prune", "-f"],
            ["image", "prune", "-f"],
            ["container", "prune", "-f"],
            ["volume", "prune", "-f"],
        ])
    }

    @Test func filesystemItemCannotSpoofAnExecutableDockerAction() async throws {
        let recorder = CommandRecorder()
        let docker = module(recorder: recorder)
        let spoofed = CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/var/lib/docker/$(touch-pwned)"),
            size: 1024,
            type: .directory,
            module: "docker",
            moduleName: "Docker Images"
        )
        let unverified = CleanupItem(
            id: UUID(),
            action: .docker(.pruneVolumes),
            size: 0
        )

        let result = try await docker.clean(items: [spoofed, unverified], dryRun: false)
        let invocations = await recorder.recordedInvocations()

        #expect(invocations.isEmpty)
        #expect(result.itemsProcessed == 0)
        #expect(result.errors.count == 2)
    }

    @Test func deletionGuardBlocksOversizedDockerActionBeforeExecution() async {
        let recorder = CommandRecorder()
        let engine = ScanEngine(modules: [module(recorder: recorder)])
        let oversized = CleanupItem(
            id: UUID(),
            action: .docker(.pruneBuildCache),
            size: 10_737_418_241
        )

        do {
            _ = try await engine.clean(items: [oversized], dryRun: false)
            Issue.record("Expected the Docker action to be blocked by DeletionGuard")
        } catch let error as ScanEngineError {
            guard case .deletionBlocked = error else {
                Issue.record("Expected .deletionBlocked, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected ScanEngineError, got \(error)")
        }

        let invocations = await recorder.recordedInvocations()
        #expect(invocations.isEmpty)
    }
}
