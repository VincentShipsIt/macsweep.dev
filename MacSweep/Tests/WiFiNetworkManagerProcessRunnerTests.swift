import Foundation
import Testing
@testable import MacSweepCore

private actor WiFiCommandRecorder {
    struct Invocation: Equatable, Sendable {
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

struct WiFiNetworkManagerProcessRunnerTests {
    @Test func removalUsesExactArgvAndTimeout() async throws {
        let recorder = WiFiCommandRecorder(outcome: .result(ProcessResult(
            status: 0,
            output: "",
            error: ""
        )))

        try await WiFiNetworkManager.removeNetwork(
            "Cafe Wi-Fi; $(touch /tmp/never)",
            interface: "en7"
        ) { executable, arguments, timeout in
            try await recorder.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }

        #expect(await recorder.recordedInvocations() == [
            WiFiCommandRecorder.Invocation(
                executable: "/usr/sbin/networksetup",
                arguments: [
                    "-removepreferredwirelessnetwork",
                    "en7",
                    "Cafe Wi-Fi; $(touch /tmp/never)",
                ],
                timeout: WiFiNetworkManager.removalTimeout
            )
        ])
        #expect(WiFiNetworkManager.removalTimeout == 30)
    }

    @Test func nonzeroExitMapsToRemoveNetworkFailed() async {
        await #expect(throws: NetworkError.self) {
            try await WiFiNetworkManager.removeNetwork("Office", interface: "en0") { _, _, _ in
                ProcessResult(status: 1, output: "", error: "networksetup rejected removal")
            }
        }
    }

    @Test func launchFailureMapsToRemoveNetworkFailed() async {
        await #expect(throws: NetworkError.self) {
            try await WiFiNetworkManager.removeNetwork("Office", interface: "en0") { _, _, _ in
                throw ProcessRunnerError.launchFailed("fixture")
            }
        }
    }

    @Test func timeoutMapsToRemoveNetworkFailed() async {
        await #expect(throws: NetworkError.self) {
            try await WiFiNetworkManager.removeNetwork("Office", interface: "en0") { _, _, _ in
                throw ProcessRunnerError.timedOut(
                    after: WiFiNetworkManager.removalTimeout,
                    partialResult: ProcessResult(
                        status: -1,
                        output: "",
                        error: "fixture timeout"
                    )
                )
            }
        }
    }
}
