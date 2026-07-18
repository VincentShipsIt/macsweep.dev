import Foundation
import Testing
@testable import MacSweepCore

private actor AssistantCommandRecorder {
    struct Invocation: Sendable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    enum Outcome: Sendable {
        case result(ProcessResult)
        case failure(ProcessRunnerError)
    }

    private let outcome: Outcome
    private var invocations: [Invocation] = []

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))

        switch outcome {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }
}

struct AssistantConversationProcessRunnerTests {
    @Test func claudeSuccessUsesExactArgvAndLongRunningTimeout() async throws {
        let payload = """
        {
          "explanation": "Provider plan",
          "modules": [],
          "customTargets": [],
          "recommendedRules": []
        }
        """
        let recorder = AssistantCommandRecorder(outcome: .result(ProcessResult(
            status: 0,
            output: "\n\(payload)\n",
            error: ""
        )))
        let service = makeService(recorder: recorder)

        let plan = await service.plan(
            prompt: "inspect caches",
            moduleCatalog: [],
            existingRules: [],
            config: claudeConfiguration,
            statuses: [claudeStatus]
        )

        let invocations = await recorder.recordedInvocations()
        let invocation = try #require(invocations.first)
        #expect(invocation.executable == "/usr/bin/env")
        #expect(invocation.timeout == AssistantProviderProcess.timeout)
        #expect(invocation.timeout == 600)
        #expect(invocation.arguments.count == 9)
        #expect(Array(invocation.arguments.prefix(7)) == [
            "test-claude",
            "-p",
            "--model", "test-model",
            "--effort", "high",
            "--json-schema"
        ])
        #expect(invocation.arguments[7].contains(#""required": ["explanation", "modules""#))
        #expect(invocation.arguments[8].contains("User request:\ninspect caches"))
        #expect(plan.provider == .claude)
        #expect(!plan.usedFallback)
        #expect(plan.explanation == "Provider plan")
    }

    @Test func nonzeroExitPrefersStderrInProviderError() async {
        let recorder = AssistantCommandRecorder(outcome: .result(ProcessResult(
            status: 7,
            output: "stdout detail",
            error: "stderr detail"
        )))

        let plan = await fallbackPlan(recorder: recorder)

        #expect(plan.usedFallback)
        #expect(plan.explanation.contains("Claude failed: stderr detail"))
        #expect(!plan.explanation.contains("stdout detail"))
    }

    @Test func nonzeroExitFallsBackToStdoutWhenStderrIsEmpty() async {
        let recorder = AssistantCommandRecorder(outcome: .result(ProcessResult(
            status: 7,
            output: "stdout detail",
            error: ""
        )))

        let plan = await fallbackPlan(recorder: recorder)

        #expect(plan.usedFallback)
        #expect(plan.explanation.contains("Claude failed: stdout detail"))
    }

    @Test func launchFailureUsesProviderErrorSurface() async {
        let recorder = AssistantCommandRecorder(outcome: .failure(
            .launchFailed("test executable missing")
        ))

        let plan = await fallbackPlan(recorder: recorder)

        #expect(plan.usedFallback)
        #expect(plan.explanation.contains(
            "Claude failed: Failed to launch process: test executable missing"
        ))
    }

    @Test func timeoutPreservesCapturedStderrInProviderError() async {
        let recorder = AssistantCommandRecorder(outcome: .failure(.timedOut(
            after: AssistantProviderProcess.timeout,
            partialResult: ProcessResult(
                status: -1,
                output: "partial stdout",
                error: "partial stderr"
            )
        )))

        let plan = await fallbackPlan(recorder: recorder)

        #expect(plan.usedFallback)
        #expect(plan.explanation.contains("Claude failed: partial stderr"))
        #expect(!plan.explanation.contains("partial stdout"))
    }

    private func fallbackPlan(recorder: AssistantCommandRecorder) async -> AssistantScanPlan {
        let service = makeService(recorder: recorder)
        return await service.plan(
            prompt: "inspect caches",
            moduleCatalog: [],
            existingRules: [],
            config: claudeConfiguration,
            statuses: [claudeStatus]
        )
    }

    private func makeService(recorder: AssistantCommandRecorder) -> AssistantConversationService {
        let providerProcess = AssistantProviderProcess { executable, arguments, timeout in
            try await recorder.run(executable: executable, arguments: arguments, timeout: timeout)
        }
        return AssistantConversationService(providerProcess: providerProcess)
    }

    private var claudeConfiguration: AssistantProvidersConfiguration {
        AssistantProvidersConfiguration(
            defaultProvider: .claude,
            fallbackOrder: [],
            providers: [
                .claude: AssistantProviderConfiguration(
                    enabled: true,
                    command: "test-claude",
                    model: "test-model",
                    reasoningEffort: "high"
                )
            ]
        )
    }

    private var claudeStatus: AssistantProviderStatus {
        AssistantProviderStatus(
            provider: .claude,
            command: "test-claude",
            state: .ready,
            installed: true,
            configured: true,
            model: "test-model",
            reasoningEffort: "high",
            note: nil
        )
    }
}
