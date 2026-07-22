import Foundation
import Testing
@testable import MacSweepCore

@MainActor
struct HomebrewServiceProcessRunnerTests {
    @Test func nonStreamingCommandUsesExactArgvAndTimeout() async {
        let recorder = HomebrewCommandRecorder(
            response: .result(ProcessResult(
                status: 0,
                output: #"{"formulae":[]}"#,
                error: "brew progress"
            ))
        )
        let service = HomebrewService { executable, arguments, timeout in
            try await recorder.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }

        let result = await service.runBrew(
            "/opt/homebrew/bin/brew",
            ["outdated", "--json=v2"]
        )

        #expect(result.status == 0)
        #expect(result.output == #"{"formulae":[]}"#)
        #expect(result.error == "brew progress")
        #expect(await recorder.recordedInvocations() == [
            HomebrewCommandInvocation(
                executable: "/opt/homebrew/bin/brew",
                arguments: ["outdated", "--json=v2"],
                timeout: 300
            )
        ])
    }

    @Test func nonzeroExitPreservesCapturedResult() async {
        let expected = ProcessResult(
            status: 2,
            output: "partial output",
            error: "brew rejected the command"
        )
        let service = makeService(response: .result(expected))

        let result = await service.runBrew("/usr/local/bin/brew", ["cleanup", "-s"])

        #expect(result.status == expected.status)
        #expect(result.output == expected.output)
        #expect(result.error == expected.error)
    }

    @Test func launchFailurePreservesFailureStatusContract() async {
        let service = makeService(response: .error(.launchFailed("brew unavailable")))

        let result = await service.runBrew("/missing/brew", ["leaves"])

        #expect(result.status == 1)
        #expect(result.output.isEmpty)
        #expect(result.error.contains("brew unavailable"))
    }

    @Test func timeoutPreservesPartialOutputAndReturnsTimeoutStatus() async {
        let service = makeService(response: .error(.timedOut(
            after: 300,
            partialResult: ProcessResult(
                status: -1,
                output: "partial stdout",
                error: "partial stderr"
            )
        )))

        let result = await service.runBrew("/opt/homebrew/bin/brew", ["deps", "swiftlint"])

        #expect(result.status == 124)
        #expect(result.output == "partial stdout")
        #expect(result.error.contains("partial stderr"))
        #expect(result.error.contains("timed out after 300.0 seconds"))
    }

    @Test func commandLogKeepsStderrOutsideParseableStdout() {
        let result = ProcessResult(
            status: 0,
            output: #"{"formulae":[]}"#,
            error: "brew progress"
        )

        #expect(result.output == #"{"formulae":[]}"#)
        #expect(HomebrewService.commandLog(result) == """
        {"formulae":[]}
        brew progress
        """)
    }

    @Test func streamedUpgradeUsesExactArgvTimeoutAndForwardsBothPipes() async {
        let recorder = HomebrewStreamingCommandRecorder(
            response: .result(ProcessResult(
                status: 0,
                output: "Downloading package\n",
                error: "Pouring package\n"
            )),
            chunks: [
                (.standardOutput, Data("Downloading package\n".utf8)),
                (.standardError, Data("Pouring package\n".utf8))
            ]
        )
        let service = makeStreamingService(recorder: recorder)

        await service.upgradeAll()

        #expect(await recorder.recordedInvocations() == [
            HomebrewStreamingCommandInvocation(
                executable: HomebrewPaths.brewPath ?? "/usr/local/bin/brew",
                arguments: ["upgrade"],
                timeout: 300
            )
        ])
        #expect(service.upgradeLog.contains("Downloading package\n"))
        #expect(service.upgradeLog.contains("Pouring package\n"))
        #expect(service.upgradeLog.hasSuffix("✅ Done (exit code: 0)"))
        #expect(service.lastUpgradeSucceeded == true)
    }

    @Test func streamedUpgradePreservesNonzeroExit() async {
        let recorder = HomebrewStreamingCommandRecorder(
            response: .result(ProcessResult(
                status: 7,
                output: "",
                error: "upgrade failed\n"
            )),
            chunks: [(.standardError, Data("upgrade failed\n".utf8))]
        )
        let service = makeStreamingService(recorder: recorder)

        await service.upgradeAll()

        #expect(service.upgradeLog.contains("upgrade failed\n"))
        #expect(service.upgradeLog.hasSuffix("❌ Error (exit code: 7)"))
        #expect(service.lastUpgradeSucceeded == false)
    }

    @Test func streamedUpgradeReportsLaunchFailure() async {
        let recorder = HomebrewStreamingCommandRecorder(
            response: .error(.launchFailed("brew unavailable"))
        )
        let service = makeStreamingService(recorder: recorder)

        await service.upgradeAll()

        #expect(service.upgradeLog.contains("failed to launch brew: brew unavailable"))
        #expect(service.lastUpgradeSucceeded == false)
    }

    @Test func streamedUpgradeReportsTimeoutAfterForwardingPartialOutput() async {
        let partialResult = ProcessResult(
            status: -1,
            output: "partial stdout\n",
            error: "partial stderr\n"
        )
        let recorder = HomebrewStreamingCommandRecorder(
            response: .error(.timedOut(after: 300, partialResult: partialResult)),
            chunks: [
                (.standardOutput, Data(partialResult.output.utf8)),
                (.standardError, Data(partialResult.error.utf8))
            ]
        )
        let service = makeStreamingService(recorder: recorder)

        await service.upgradeAll()

        #expect(service.upgradeLog.contains("partial stdout\n"))
        #expect(service.upgradeLog.contains("partial stderr\n"))
        #expect(service.upgradeLog.hasSuffix("Homebrew upgrade timed out after 300.0 seconds"))
        #expect(service.lastUpgradeSucceeded == false)
    }

    @Test func streamedUpgradePreservesUTF8SplitAcrossPipeReads() async {
        let recorder = HomebrewStreamingCommandRecorder(
            response: .result(ProcessResult(status: 0, output: "", error: "")),
            chunks: [
                (.standardOutput, Data([0x63, 0x61, 0x66, 0xC3])),
                (.standardOutput, Data([0xA9, 0x0A])),
                (.standardError, Data([0xE2, 0x98])),
                (.standardError, Data([0x95, 0xEF, 0xB8])),
                (.standardError, Data([0x8F, 0x0A]))
            ]
        )
        let service = makeStreamingService(recorder: recorder)

        await service.upgradeAll()

        #expect(service.upgradeLog.contains("café\n"))
        #expect(service.upgradeLog.contains("☕️\n"))
        #expect(!service.upgradeLog.contains("�"))
    }

    @Test func streamedUpgradeFlushesIncompleteUTF8AtEndOfOutput() async {
        let recorder = HomebrewStreamingCommandRecorder(
            response: .result(ProcessResult(status: 0, output: "", error: "")),
            chunks: [(.standardOutput, Data([0xE2, 0x82]))]
        )
        let service = makeStreamingService(recorder: recorder)

        await service.upgradeAll()

        #expect(service.upgradeLog.contains("�"))
        #expect(service.upgradeLog.hasSuffix("✅ Done (exit code: 0)"))
    }

    private func makeService(response: HomebrewCommandResponse) -> HomebrewService {
        let recorder = HomebrewCommandRecorder(response: response)
        return HomebrewService { executable, arguments, timeout in
            try await recorder.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    }

    private func makeStreamingService(
        recorder: HomebrewStreamingCommandRecorder
    ) -> HomebrewService {
        HomebrewService(
            streamingCommandRunner: { executable, arguments, timeout, onOutput in
                try await recorder.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    onOutput: onOutput
                )
            },
            commandRunner: { _, _, _ in
                ProcessResult(
                    status: 0,
                    output: #"{"formulae":[],"casks":[]}"#,
                    error: ""
                )
            }
        )
    }
}

private struct HomebrewCommandInvocation: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

private enum HomebrewCommandResponse: Sendable {
    case result(ProcessResult)
    case error(ProcessRunnerError)
}

private actor HomebrewCommandRecorder {
    private let response: HomebrewCommandResponse
    private var invocations: [HomebrewCommandInvocation] = []

    init(response: HomebrewCommandResponse) {
        self.response = response
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        invocations.append(HomebrewCommandInvocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))

        switch response {
        case .result(let result):
            return result
        case .error(let error):
            throw error
        }
    }

    func recordedInvocations() -> [HomebrewCommandInvocation] {
        invocations
    }
}

private struct HomebrewStreamingCommandInvocation: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

private enum HomebrewStreamingCommandResponse: Sendable {
    case result(ProcessResult)
    case error(ProcessRunnerError)
}

private actor HomebrewStreamingCommandRecorder {
    private let response: HomebrewStreamingCommandResponse
    private let chunks: [(ProcessOutputStream, Data)]
    private var invocations: [HomebrewStreamingCommandInvocation] = []

    init(
        response: HomebrewStreamingCommandResponse,
        chunks: [(ProcessOutputStream, Data)] = []
    ) {
        self.response = response
        self.chunks = chunks
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        onOutput: ProcessOutputHandler
    ) throws -> ProcessResult {
        invocations.append(HomebrewStreamingCommandInvocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        for (stream, chunk) in chunks {
            onOutput(stream, chunk)
        }

        switch response {
        case .result(let result):
            return result
        case .error(let error):
            throw error
        }
    }

    func recordedInvocations() -> [HomebrewStreamingCommandInvocation] {
        invocations
    }
}
