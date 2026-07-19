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
