import Darwin
import Foundation
import Testing

@testable import MacSweepCore

struct ProcessRunnerCancellationTests {
    @Test func cancellationTerminatesOwnedChildPromptly() async throws {
        let temp = try TempTestDirectory(prefix: "ProcessCancellation")
        let pidFile = temp.url.appendingPathComponent("pid")
        let task = Task {
            try await ProcessRunner.run(
                executable: "/bin/sh", arguments: ["-c", "echo $$ > \"$1\"; exec sleep 30", "fixture", pidFile.path],
                timeout: 20)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(
            Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled process must throw")
        } catch is CancellationError {} catch { Issue.record("Unexpected cancellation: \(error)") }
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
}
