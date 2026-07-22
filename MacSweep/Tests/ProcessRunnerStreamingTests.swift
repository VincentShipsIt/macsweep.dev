import Foundation
import Testing
@testable import MacSweepCore

struct ProcessRunnerStreamingTests {
    @Test func streamsBothPipesWhileRetainingCapturedResult() async throws {
        let collector = ProcessOutputCollector()

        let result = try await ProcessRunner.runStreaming(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "printf 'streamed stdout\\n'; printf 'streamed stderr\\n' >&2"
            ],
            onOutput: { stream, chunk in
                collector.append(chunk, from: stream)
            }
        )

        #expect(collector.standardOutput == result.output)
        #expect(collector.standardError == result.error)
        #expect(result.output == "streamed stdout\n")
        #expect(result.error == "streamed stderr\n")
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func append(_ chunk: Data, from stream: ProcessOutputStream) {
        lock.lock()
        switch stream {
        case .standardOutput:
            output.append(chunk)
        case .standardError:
            error.append(chunk)
        }
        lock.unlock()
    }

    var standardOutput: String {
        lock.lock()
        let snapshot = output
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }

    var standardError: String {
        lock.lock()
        let snapshot = error
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}
