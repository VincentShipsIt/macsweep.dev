import Darwin
import Foundation
import Testing
@testable import MacSweepCore

@Suite(.serialized)
struct ProcessRunnerPipelineTests {
    private func makeExecutable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-pipeline-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func expectReaped(_ pids: [pid_t]) {
        for pid in pids {
            errno = 0
            let probeResult = Darwin.kill(pid, 0)
            let probeError = errno
            #expect(probeResult == -1)
            #expect(probeError == ESRCH)

            var rawStatus: Int32 = 0
            errno = 0
            let waitResult = Darwin.waitpid(pid, &rawStatus, WNOHANG)
            let waitError = errno
            #expect(waitResult == -1)
            #expect(waitError == ECHILD)
        }
    }

    @Test func connectsStagesAndNeverInterpretsArgumentsAsShell() async throws {
        let payload = "$(whoami) `id` ; touch /tmp/macsweep-must-not-exist"
        let result = try await ProcessRunner.runPipeline(
            stages: [
                ProcessPipelineStage(
                    executable: "/usr/bin/printf",
                    arguments: ["%s", payload]
                ),
                ProcessPipelineStage(
                    executable: "/usr/bin/tr",
                    arguments: ["a-z", "A-Z"]
                ),
                ProcessPipelineStage(executable: "/bin/cat")
            ],
            timeout: 10
        )

        #expect(result.status == 0)
        #expect(result.output == payload.uppercased())
        #expect(result.error.isEmpty)
    }

    @Test func drainsLargeTailOutputWithoutDeadlock() async throws {
        let scriptURL = try makeExecutable("""
        #!/bin/sh
        i=0
        while [ $i -lt 5000 ]; do
          echo "PIPELINE ........................................... line $i"
          i=$((i + 1))
        done
        """)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try await ProcessRunner.runPipeline(
            stages: [
                ProcessPipelineStage(executable: scriptURL.path),
                ProcessPipelineStage(executable: "/bin/cat")
            ],
            timeout: 30
        )

        #expect(result.output.utf8.count > 200_000)
        #expect(result.output.split(separator: "\n").count == 5000)
    }

    @Test func nonzeroStageThrowsDeterministicStatus() async {
        do {
            _ = try await ProcessRunner.runPipeline(
                stages: [
                    ProcessPipelineStage(executable: "/usr/bin/false"),
                    ProcessPipelineStage(executable: "/bin/cat")
                ]
            )
            Issue.record("Expected the failed first stage to be rejected")
        } catch let error as ProcessRunnerError {
            guard case .nonZeroExit(let status, let stderr) = error else {
                Issue.record("Expected nonZeroExit, got \(error)")
                return
            }
            #expect(status == 1)
            #expect(stderr == "Pipeline stage 1 exited with status 1")
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
    }

    @Test func launchFailureTerminatesAlreadyStartedStages() async {
        let recorder = PipelinePIDRecorder()
        do {
            _ = try await ProcessRunner.runPipeline(
                stages: [
                    ProcessPipelineStage(executable: "/usr/bin/printf", arguments: ["data"]),
                    ProcessPipelineStage(executable: "/missing/pipeline-stage"),
                    ProcessPipelineStage(executable: "/bin/cat")
                ],
                onStageStartedForTesting: { _, pid in recorder.append(pid) }
            )
            Issue.record("Expected the missing middle stage to fail")
        } catch let error as ProcessRunnerError {
            guard case .launchFailed(let reason) = error else {
                Issue.record("Expected launchFailed, got \(error)")
                return
            }
            #expect(reason.contains("Pipeline stage 2 failed"))
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
        #expect(recorder.pids.count == 1)
        expectReaped(recorder.pids)
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutTerminatesAndReapsEveryStage() async {
        let hangingStageURL: URL
        do {
            hangingStageURL = try makeExecutable("""
            #!/bin/sh
            exec 1>&-
            exec /bin/sleep 5
            """)
        } catch {
            Issue.record("Failed to create the hanging pipeline stage: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: hangingStageURL) }

        let started = Date()
        let recorder = PipelinePIDRecorder()
        do {
            _ = try await ProcessRunner.runPipeline(
                stages: [
                    ProcessPipelineStage(
                        executable: "/usr/bin/printf",
                        arguments: ["ready"]
                    ),
                    ProcessPipelineStage(executable: hangingStageURL.path),
                    ProcessPipelineStage(executable: "/bin/cat")
                ],
                timeout: 0.4,
                onStageStartedForTesting: { _, pid in recorder.append(pid) }
            )
            Issue.record("Expected the pipeline to time out")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let timeout, _) = error else {
                Issue.record("Expected timedOut, got \(error)")
                return
            }
            #expect(timeout == 0.4)
            #expect(Date().timeIntervalSince(started) < 3)
        } catch {
            Issue.record("Expected ProcessRunnerError, got \(error)")
        }
        #expect(recorder.pids.count == 3)
        expectReaped(recorder.pids)
    }

    @Test func emptyPipelineReturnsAnEmptySuccessfulResult() async throws {
        let result = try await ProcessRunner.runPipeline(stages: [])

        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.error.isEmpty)
    }

    @Test func invalidTimeoutFailsBeforeLaunch() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.runPipeline(
                stages: [ProcessPipelineStage(executable: "/usr/bin/true")],
                timeout: .infinity
            )
        }
    }
}

private final class PipelinePIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPIDs: [pid_t] = []

    func append(_ pid: pid_t) {
        lock.lock()
        recordedPIDs.append(pid)
        lock.unlock()
    }

    var pids: [pid_t] {
        lock.lock()
        let snapshot = recordedPIDs
        lock.unlock()
        return snapshot
    }
}
