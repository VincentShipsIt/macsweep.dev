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
    @Test func listingUsesExactArgvAndTimeoutAndPreservesParsing() async {
        let recorder = WiFiCommandRecorder(outcome: .result(ProcessResult(
            status: 0,
            output: """
            Preferred networks on en7:
                Office Wi-Fi
              Cafe Guest

            """,
            error: "ignored diagnostic"
        )))

        let networks = await WiFiNetworkManager.savedNetworks(
            interface: "en7",
            currentSSID: "Office Wi-Fi",
            commandRunner: { executable, arguments, timeout in
                try await recorder.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
            }
        )

        #expect(networks.map(\.ssid) == ["Office Wi-Fi", "Cafe Guest"])
        #expect(networks.map(\.isCurrentlyConnected) == [true, false])
        #expect(await recorder.recordedInvocations() == [
            WiFiCommandRecorder.Invocation(
                executable: "/usr/sbin/networksetup",
                arguments: ["-listpreferredwirelessnetworks", "en7"],
                timeout: WiFiNetworkManager.listingTimeout
            )
        ])
        #expect(WiFiNetworkManager.listingTimeout == 30)
    }

    @Test func listingNonzeroExitFailsClosedWithoutTrustingOutput() async {
        let networks = await WiFiNetworkManager.savedNetworks(
            interface: "en0",
            currentSSID: "Must Not Surface",
            commandRunner: { _, _, _ in
                ProcessResult(
                    status: 1,
                    output: "Header\nMust Not Surface\n",
                    error: "listing failed"
                )
            }
        )

        #expect(networks.isEmpty)
    }

    @Test func listingWithoutCurrentNetworkLeavesEveryEntryDisconnected() async {
        let networks = await WiFiNetworkManager.savedNetworks(
            interface: "en0",
            currentSSID: nil,
            commandRunner: { _, _, _ in
                ProcessResult(
                    status: 0,
                    output: "Header\nOffice\nGuest\n",
                    error: ""
                )
            }
        )

        #expect(networks.map(\.ssid) == ["Office", "Guest"])
        #expect(networks.allSatisfy { !$0.isCurrentlyConnected })
    }

    @Test func listingHeaderWithoutNetworksReturnsEmpty() async {
        let networks = await WiFiNetworkManager.savedNetworks(
            interface: "en0",
            currentSSID: "Office",
            commandRunner: { _, _, _ in
                ProcessResult(
                    status: 0,
                    output: "Preferred networks on en0:\n",
                    error: ""
                )
            }
        )

        #expect(networks.isEmpty)
    }

    @Test func listingLaunchFailureFailsClosed() async {
        let networks = await WiFiNetworkManager.savedNetworks(
            interface: "en0",
            currentSSID: nil,
            commandRunner: { _, _, _ in
                throw ProcessRunnerError.launchFailed("fixture")
            }
        )

        #expect(networks.isEmpty)
    }

    @Test func listingTimeoutFailsClosedWithoutTrustingPartialOutput() async {
        let networks = await WiFiNetworkManager.savedNetworks(
            interface: "en0",
            currentSSID: nil,
            commandRunner: { _, _, _ in
                throw ProcessRunnerError.timedOut(
                    after: WiFiNetworkManager.listingTimeout,
                    partialResult: ProcessResult(
                        status: -1,
                        output: "Header\nPartial Network\n",
                        error: ""
                    )
                )
            }
        )

        #expect(networks.isEmpty)
    }

    @Test func listingInvalidUTF8FailsClosed() async {
        let networks = await WiFiNetworkManager.savedNetworks(
            interface: "en0",
            currentSSID: nil,
            commandRunner: { _, _, _ in
                ProcessResult(
                    status: 0,
                    output: "Header\nReplacement Character Network\n",
                    error: "",
                    outputWasValidUTF8: false
                )
            }
        )

        #expect(networks.isEmpty)
    }

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
                    "Cafe Wi-Fi; $(touch /tmp/never)"
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
