import Testing
import Foundation
@testable import MacSweepCore

/// Unit coverage for the shared `ProcessRunner`. These run real system binaries
/// (echo/false/sleep) plus one script fixture, exercising the four guarantees the
/// runner exists to provide: argv-only execution, a watchdog timeout, concurrent
/// large-output draining (no two-pipe deadlock), and stdout/stderr separation.
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
        let result = try await ProcessRunner.run(executable: "/usr/bin/false")
        #expect(result.status != 0)
        #expect(!result.didSucceed)
        // Opt-in throwing convenience surfaces the failure as an error.
        #expect(throws: ProcessRunnerError.self) { try result.checkedSuccess() }
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
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.4)
        }
    }

    @Test func launchFailureThrows() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(executable: "/nonexistent/definitely-not-a-binary")
        }
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
}
