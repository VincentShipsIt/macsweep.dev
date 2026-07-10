import Testing
import Foundation
import Darwin
@testable import MacSweepCore

/// Unit coverage for the shared `ProcessRunner`. These run real system binaries
/// (echo/false/sleep) plus one script fixture, exercising the four guarantees the
/// runner exists to provide: argv-only execution, a watchdog timeout, concurrent
/// large-output draining (no two-pipe deadlock), and stdout/stderr separation.
@Suite(.serialized)
struct ProcessRunnerTests {
    /// Write an executable `/bin/sh` script fixture and return its URL.
    private func makeExecutable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-proc-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func capturesStdoutAndZeroExit() async throws {
        let result = try await ProcessRunner.run(executable: "/bin/echo", arguments: ["hello world"])
        #expect(result.status == 0)
        #expect(result.didSucceed)
        #expect(result.output == "hello world\n")
        #expect(result.error.isEmpty)
    }

    @Test func argumentsAreNeverShellInterpreted() async throws {
        // /bin/echo prints its argv verbatim. If any shell were involved the
        // command substitution / metacharacters would expand or execute. argv-only
        // means the whole thing stays literal.
        let payload = "$(whoami) `id` ; rm -rf / && echo pwned"
        let result = try await ProcessRunner.run(executable: "/bin/echo", arguments: [payload])
        #expect(result.output == payload + "\n")
    }

    @Test func nonZeroExitIsReturnedNotThrown() async throws {
        let scriptURL = try makeExecutable("""
        #!/bin/sh
        echo "ordinary stderr" 1>&2
        exit 23
        """)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try await ProcessRunner.run(executable: scriptURL.path)
        #expect(result.status == 23)
        #expect(!result.didSucceed)
        do {
            try result.checkedSuccess()
            Issue.record("Expected checkedSuccess to reject status 23")
        } catch let error as ProcessRunnerError {
            switch error {
            case .nonZeroExit(let status, let stderr):
                #expect(status == 23)
                #expect(stderr == "ordinary stderr\n")
            case .timedOut:
                Issue.record("Ordinary nonzero exit was incorrectly reported as a timeout")
            case .launchFailed(let reason):
                Issue.record("Completed process was incorrectly reported as launch failure: \(reason)")
            }
        }
    }

    @Test func stderrIsCapturedSeparatelyFromStdout() async throws {
        let script = """
        #!/bin/sh
        echo "this is stdout"
        echo "this is stderr" 1>&2
        exit 3
        """
        let scriptURL = try makeExecutable(script)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try await ProcessRunner.run(executable: scriptURL.path)
        #expect(result.status == 3)
        #expect(result.output == "this is stdout\n")
        #expect(result.error == "this is stderr\n")
    }

    @Test func timesOutAndTerminatesAStuckChild() async {
        // /bin/sleep 5 with a 0.4 s ceiling: the watchdog must terminate it and the
        // call must throw .timedOut rather than block for 5 s.
        do {
            _ = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.4)
            Issue.record("Expected sleep to time out")
        } catch let error as ProcessRunnerError {
            if case .timedOut = error { return }
            Issue.record("Expected timedOut, got \(error)")
        } catch {
            Issue.record("Expected ProcessRunnerError.timedOut, got \(error)")
        }
    }

    @Test func launchFailureThrows() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(executable: "/nonexistent/definitely-not-a-binary")
        }
    }

    @Test func invalidTimeoutsFailBeforeLaunch() async {
        for timeout in [TimeInterval.nan, .infinity, -1, .greatestFiniteMagnitude] {
            do {
                _ = try await ProcessRunner.run(executable: "/usr/bin/true", timeout: timeout)
                Issue.record("Expected invalid timeout \(timeout) to be rejected")
            } catch let error as ProcessRunnerError {
                if case .launchFailed = error { continue }
                Issue.record("Expected launchFailed for invalid timeout, got \(error)")
            } catch {
                Issue.record("Expected ProcessRunnerError.launchFailed, got \(error)")
            }
        }
    }

    @Test func expiredDeadlineDoesNotEnterAnUnboundedWaitpidRetry() {
        let started = DispatchTime.now()
        let status = ProcessRunner.waitForChildForTesting(getpid(), until: .now())
        let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds

        #expect(status == nil)
        #expect(elapsed < 100_000_000)
    }

    @Test func largeOutputOnBothPipesDrainsWithoutDeadlockAndStaysSeparate() async throws {
        // ~250 KB on EACH of stdout and stderr, interleaved — far past the 64 KB
        // pipe buffer. Sequential drain (wait-then-read) would deadlock here; a
        // merged stream would fail separation. This is the core B2 guarantee.
        let script = """
        #!/bin/sh
        i=0
        while [ $i -lt 4000 ]; do
          echo "OUT ................................................ line $i"
          echo "ERR ................................................ line $i" 1>&2
          i=$((i + 1))
        done
        """
        let scriptURL = try makeExecutable(script)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try await ProcessRunner.run(executable: scriptURL.path, timeout: 30)

        #expect(result.status == 0)
        #expect(result.output.utf8.count > 100_000)
        #expect(result.error.utf8.count > 100_000)
        // Separation: stdout carries only OUT lines, stderr only ERR lines.
        #expect(result.output.contains("OUT ") && !result.output.contains("ERR "))
        #expect(result.error.contains("ERR ") && !result.error.contains("OUT "))
        // No truncation — every line of both streams is accounted for.
        #expect(result.output.split(separator: "\n").count == 4000)
        #expect(result.error.split(separator: "\n").count == 4000)
    }

    @Test(.timeLimit(.minutes(1)))
    func sigtermIgnoringProcessIsForceKilledWithinBound() async {
        // The fixture ignores SIGTERM but self-expires after four seconds so a
        // regression fails slowly instead of hanging the test process forever.
        let scriptURL: URL
        do {
            scriptURL = try makeExecutable("""
            #!/bin/sh
            trap '' TERM
            echo "started"
            exec /bin/sleep 4
            """)
        } catch {
            Issue.record("Could not create process fixture: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let started = Date()
        do {
            _ = try await ProcessRunner.run(executable: scriptURL.path, timeout: 0.5)
            Issue.record("Expected SIGTERM-resistant process to time out")
        } catch let error as ProcessRunnerError {
            if case .timedOut = error {
                #expect(Date().timeIntervalSince(started) < 3)
                return
            }
            Issue.record("Expected timedOut, got \(error)")
        } catch {
            Issue.record("Expected ProcessRunnerError.timedOut, got \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutPreservesPartialStdoutAndStderr() async throws {
        let scriptURL = try makeExecutable("""
        #!/bin/sh
        echo "stdout before timeout"
        echo "stderr before timeout" 1>&2
        trap '' TERM
        exec /bin/sleep 4
        """)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        do {
            _ = try await ProcessRunner.run(executable: scriptURL.path, timeout: 0.5)
            Issue.record("Expected process lifecycle to time out")
        } catch let error as ProcessRunnerError {
            switch error {
            case .timedOut(let timeout, let partialResult):
                #expect(timeout == 0.5)
                #expect(partialResult.output == "stdout before timeout\n")
                #expect(partialResult.error == "stderr before timeout\n")
            case .nonZeroExit(let status, _):
                Issue.record("Timeout was incorrectly reported as exit status \(status)")
            case .launchFailed(let reason):
                Issue.record("Timeout fixture failed to launch: \(reason)")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func descendantRetainingStdoutCannotHoldRunOpen() async {
        // The direct child exits immediately while its descendant keeps the pipe
        // open. The descendant also self-expires, keeping the old failure bounded.
        let scriptURL: URL
        do {
            scriptURL = try makeExecutable("""
            #!/bin/sh
            sleep 4 &
            echo "parent complete"
            exit 0
            """)
        } catch {
            Issue.record("Could not create process fixture: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let started = Date()
        do {
            _ = try await ProcessRunner.run(executable: scriptURL.path, timeout: 0.5)
            Issue.record("Expected inherited pipe descriptor to time out")
        } catch let error as ProcessRunnerError {
            if case .timedOut(_, let partialResult) = error {
                #expect(partialResult.output.contains("parent complete"))
                #expect(Date().timeIntervalSince(started) < 3)
                return
            }
            Issue.record("Expected timedOut, got \(error)")
        } catch {
            Issue.record("Expected ProcessRunnerError.timedOut, got \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutCleansUpDescendantsThatCloseTheirOutput() async throws {
        // The descendant closes the captured streams, ignores SIGTERM/HUP, and
        // writes a sentinel after 2.5 seconds using only zsh builtins. A TERM-only
        // implementation lets that write happen; group SIGKILL prevents it. The
        // descendant self-exits, so even the pre-fix failure cannot leak into CI.
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-descendant-\(UUID().uuidString).ready")
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-descendant-\(UUID().uuidString).survived")
        let scriptURL = try makeExecutable("""
        #!/bin/sh
        /bin/zsh -c 'trap "" TERM HUP; print -r -- ready > "\(ready.path)"; zmodload zsh/datetime; zmodload zsh/zselect; end=$((EPOCHREALTIME + 2.5)); while ((EPOCHREALTIME < end)); do zselect -t 5; done; print -r -- survived > "\(sentinel.path)"' </dev/null >/dev/null 2>&1 &
        trap 'exit 0' TERM
        /bin/zsh -c 'trap "exit 0" TERM HUP; zmodload zsh/datetime; zmodload zsh/zselect; end=$((EPOCHREALTIME + 6)); while ((EPOCHREALTIME < end)); do zselect -t 5; done' </dev/null >/dev/null 2>&1
        """)
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: ready)
            try? FileManager.default.removeItem(at: sentinel)
        }

        let invocation = Task {
            try await ProcessRunner.run(executable: scriptURL.path, timeout: 1)
        }
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let readyObserved = Date()
        #expect(FileManager.default.fileExists(atPath: ready.path))

        do {
            _ = try await invocation.value
            Issue.record("Expected descendant process group to time out")
        } catch let error as ProcessRunnerError {
            if case .timedOut = error {
                // expected
            } else {
                Issue.record("Expected timedOut, got \(error)")
            }
        } catch {
            Issue.record("Expected ProcessRunnerError.timedOut, got \(error)")
        }
        let assertionTime = readyObserved.addingTimeInterval(2.8)
        let remaining = max(0, assertionTime.timeIntervalSinceNow)
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path))
    }
}
