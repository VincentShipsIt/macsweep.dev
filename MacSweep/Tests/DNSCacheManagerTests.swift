import Testing
import Foundation
@testable import MacSweepCore

private actor DNSCommandRecorder {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    private var invocations: [Invocation] = []

    func succeed(executable: String, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        invocations.append(Invocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
        return ProcessResult(status: 0, output: "", error: "")
    }

    func recordedInvocations() -> [Invocation] {
        invocations
    }
}

/// Contract coverage for the ordinary, unprivileged DNS cache flush.
struct DNSCacheManagerTests {
    @Test func flushUsesExactArgvAndAcceptsSuccessfulExit() async throws {
        let recorder = DNSCommandRecorder()

        try await DNSCacheManager.flush { executable, arguments, timeout in
            await recorder.succeed(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }

        #expect(await recorder.recordedInvocations() == [
            DNSCommandRecorder.Invocation(
                executable: "/usr/bin/dscacheutil",
                arguments: ["-flushcache"],
                timeout: 30
            )
        ])
    }

    @Test func nonzeroExitMapsToFlushFailed() async {
        await #expect(throws: DNSError.self) {
            try await DNSCacheManager.flush { _, _, _ in
                ProcessResult(status: 1, output: "", error: "flush rejected")
            }
        }
    }

    @Test func launchFailureMapsToFlushFailed() async {
        await #expect(throws: DNSError.self) {
            try await DNSCacheManager.flush { _, _, _ in
                throw ProcessRunnerError.launchFailed("fixture")
            }
        }
    }

    @Test func timeoutMapsToFlushFailed() async {
        await #expect(throws: DNSError.self) {
            try await DNSCacheManager.flush { _, _, _ in
                throw ProcessRunnerError.timedOut(
                    after: 30,
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
