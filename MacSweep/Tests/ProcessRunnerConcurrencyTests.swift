import Testing

@testable import MacSweepCore

struct ProcessRunnerConcurrencyTests {
    @Test func aBurstOfCommandsDrainsBothPipesWithoutStarvingReaders() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<96 {
                group.addTask {
                    let result = try await ProcessRunner.run(
                        executable: "/bin/sh", arguments: ["-c", "printf output; printf diagnostic >&2"], timeout: 3)
                    #expect(result.status == 0)
                    #expect(result.output == "output")
                    #expect(result.error == "diagnostic")
                }
            }
            try await group.waitForAll()
        }
    }
}
