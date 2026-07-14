import Testing
import Foundation
import Darwin
@testable import MacSweepCore

/// Exercises PrivilegedRunner's lifecycle/error mapping through its non-privileged
/// invocation seams. One test launches ordinary `osascript`, but none request
/// administrator privileges or display an authorization prompt.
@Suite(.serialized)
struct PrivilegedRunnerTests {
    private func makeExecutable(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-privileged-proc-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutIsMappedAndPreservesPartialOutput() async throws {
        // Deterministic cancellation. The prior version relied on a 1s wall-clock
        // timeout firing *after* the osascript child emitted its output — but
        // osascript cold-start under CI load can consume the whole budget, so the
        // watchdog would unlink `keepalive` before the child ran its echoes. The
        // trusted-command guard (`[ -e keepalive ]`) then skipped the script
        // entirely, leaving no partial output and flaking the assertions.
        //
        // Instead the test now owns the keepalive and triggers the timeout only
        // after the child publishes a sentinel proving both streams were written
        // and flushed. This exercises the identical osascript partial-output
        // capture path without racing process startup against the deadline.
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-partial-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let keepalive = workDirectory.appendingPathComponent("keepalive")
        #expect(FileManager.default.createFile(atPath: keepalive.path, contents: Data()))
        let flushed = workDirectory.appendingPathComponent("flushed")

        // Emit both streams, publish the sentinel only after those writes have
        // returned (so the bytes are already in the supervisor's capture files),
        // then hang while ignoring TERM so escalation must reach SIGKILL.
        let script = """
        echo "privileged stdout before timeout"
        echo "privileged stderr before timeout" 1>&2
        /usr/bin/printf '%s\\n' flushed > \(shellQuote(flushed.path))
        trap '' TERM
        exec /bin/sleep 120
        """

        let invocation = Task {
            try await PrivilegedRunner.runSupervisedShellScriptForTesting(
                script,
                timeout: 20,
                throughAppleScript: true,
                keepaliveForTesting: keepalive
            )
        }

        // Wait until the child confirms its partial output is captured. Generous
        // bound absorbs osascript startup under load without affecting the result.
        let flushedDeadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: flushed.path), Date() < flushedDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: flushed.path))

        // Now drive cancellation deterministically. The supervisor observes the
        // removed keepalive, flushes the already-captured partial output, and
        // exits 124 — a clean EOF for ProcessRunner, so capture never contends
        // with the escalation kill.
        try? FileManager.default.removeItem(at: keepalive)

        do {
            try await invocation.value
            Issue.record("Expected the privileged invocation to time out")
        } catch let error as PrivilegedRunner.EscalationError {
            switch error {
            case .timedOut(let partialResult):
                let partialOutput = partialResult.output + partialResult.error
                #expect(partialOutput.contains("privileged stdout before timeout"))
                #expect(partialOutput.contains("privileged stderr before timeout"))
            case .failed(let status):
                Issue.record("Timeout was incorrectly mapped to failure status \(status)")
            }
        }
    }

    @Test func ordinaryNonzeroExitRemainsFailure() async throws {
        let scriptURL = try makeExecutable("""
        #!/bin/sh
        echo "ordinary failure" 1>&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        do {
            let script = try String(contentsOf: scriptURL, encoding: .utf8)
            try await PrivilegedRunner.runSupervisedShellScriptForTesting(script, timeout: 10)
            Issue.record("Expected the privileged invocation to fail")
        } catch let error as PrivilegedRunner.EscalationError {
            switch error {
            case .failed(let status):
                #expect(status == 7)
            case .timedOut:
                Issue.record("Ordinary exit status was incorrectly mapped to timeout")
            }
        }
    }

    @Test func invalidTimeoutsAreRejectedBeforeSupervisorConstruction() async {
        for timeout in [TimeInterval.nan, .infinity, -1, .greatestFiniteMagnitude] {
            do {
                try await PrivilegedRunner.runSupervisedShellScriptForTesting("exit 0", timeout: timeout)
                Issue.record("Expected invalid timeout \(timeout) to be rejected")
            } catch let error as PrivilegedRunner.EscalationError {
                if case .failed(status: -1) = error { continue }
                Issue.record("Expected failed(-1) for invalid timeout, got \(error)")
            } catch {
                Issue.record("Expected PrivilegedRunner.EscalationError, got \(error)")
            }
        }

        // The public admin entry validates before constructing or launching
        // osascript, so this cannot display an authorization prompt.
        do {
            try await PrivilegedRunner.runShellScriptAsAdmin("exit 0", timeout: .nan)
            Issue.record("Expected public admin entry to reject NaN")
        } catch let error as PrivilegedRunner.EscalationError {
            if case .failed(status: -1) = error { return }
            Issue.record("Expected failed(-1) for NaN, got \(error)")
        } catch {
            Issue.record("Expected PrivilegedRunner.EscalationError, got \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rootSupervisorKillsTermIgnoringDescendantGroup() async throws {
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-admin-ready-\(UUID().uuidString)")
        let survived = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-admin-survived-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: ready)
            try? FileManager.default.removeItem(at: survived)
        }

        let script = """
        /bin/zsh -c 'print -r -- ready > "\(ready.path)"; trap "" TERM HUP; zmodload zsh/datetime; zmodload zsh/zselect; end=$((EPOCHREALTIME + 2.5)); while ((EPOCHREALTIME < end)); do zselect -t 5; done; print -r -- survived > "\(survived.path)"' </dev/null >/dev/null 2>&1 &
        trap '' TERM
        exec /bin/sleep 5
        """
        let invocation = Task {
            try await PrivilegedRunner.runSupervisedShellScriptForTesting(script, timeout: 1)
        }

        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let readyObserved = Date()
        #expect(FileManager.default.fileExists(atPath: ready.path))

        do {
            try await invocation.value
            Issue.record("Expected the supervised command to time out")
        } catch let error as PrivilegedRunner.EscalationError {
            if case .failed(let status) = error {
                Issue.record("Root supervisor timeout was mapped to failure status \(status)")
            }
        }

        let assertionTime = readyObserved.addingTimeInterval(2.8)
        let remaining = max(0, assertionTime.timeIntervalSinceNow)
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        #expect(!FileManager.default.fileExists(atPath: survived.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func rootAnchorSelfCleansAfterSupervisorDiesWithoutRemovingKeepalive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-admin-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let keepalive = directory.appendingPathComponent("keepalive")
        let ready = directory.appendingPathComponent("ready")
        let descendantPIDFile = directory.appendingPathComponent("descendant-pid")
        let stateDirectoryFile = directory.appendingPathComponent("state-directory")
        let survived = directory.appendingPathComponent("survived")
        #expect(FileManager.default.createFile(atPath: keepalive.path, contents: Data()))

        let supervisor = Process()
        var descendantPID: pid_t?
        defer {
            // Removing the keepalive/state paths makes the anchor self-clean;
            // never signal a recorded descendant PID that could have been reused.
            if supervisor.isRunning {
                _ = Darwin.kill(supervisor.processIdentifier, SIGKILL)
            }
            if let stateDirectory = try? String(contentsOf: stateDirectoryFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !stateDirectory.isEmpty {
                try? FileManager.default.removeItem(atPath: stateDirectory)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let trustedScript = """
        /usr/bin/printf '%s\n' "$state_dir" > \(shellQuote(stateDirectoryFile.path))
        /bin/zsh -c 'print -r -- $$ > \(shellQuote(descendantPIDFile.path)); print -r -- ready > \(shellQuote(ready.path)); trap "" TERM HUP; zmodload zsh/datetime; zmodload zsh/zselect; end=$((EPOCHREALTIME + 6.5)); while ((EPOCHREALTIME < end)); do zselect -t 5; done; print -r -- survived > \(shellQuote(survived.path))' </dev/null >/dev/null 2>&1 &
        trap '' TERM HUP
        exec /bin/sleep 8
        """
        supervisor.executableURL = URL(fileURLWithPath: "/bin/sh")
        supervisor.arguments = [
            "-c",
            PrivilegedRunner.makeSupervisedShellScript(
                trustedScript,
                keepalivePath: keepalive.path,
                timeout: 0.5,
                timeoutMarker: "__MACSWEEP_TEST_TIMEOUT__"
            )
        ]
        supervisor.standardOutput = FileHandle.nullDevice
        supervisor.standardError = FileHandle.nullDevice
        try supervisor.run()

        let readyDeadline = Date().addingTimeInterval(1.5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        if let rawPID = try? String(contentsOf: descendantPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let parsedPID = pid_t(rawPID) {
            descendantPID = parsedPID
        }
        #expect(descendantPID != nil)

        _ = Darwin.kill(supervisor.processIdentifier, SIGKILL)
        let supervisorExitDeadline = Date().addingTimeInterval(1)
        while supervisor.isRunning, Date() < supervisorExitDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!supervisor.isRunning)

        try await Task.sleep(nanoseconds: 5_300_000_000)
        #expect(!FileManager.default.fileExists(atPath: survived.path))
        if let descendantPID {
            #expect(Darwin.kill(descendantPID, 0) == -1 && errno == ESRCH)
        }
        let recordedStateDirectory = try String(contentsOf: stateDirectoryFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!FileManager.default.fileExists(atPath: recordedStateDirectory))
    }

    @Test(.timeLimit(.minutes(1)))
    func rootSupervisorNeverDeletesThroughReplacedKeepaliveParent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-admin-sentinel-swap-\(UUID().uuidString)")
        let sentinelParent = directory.appendingPathComponent("sentinel")
        let savedSentinelParent = directory.appendingPathComponent("saved-sentinel")
        let protectedDirectory = directory.appendingPathComponent("protected")
        let keepalive = sentinelParent.appendingPathComponent("keepalive")
        let protectedKeepalive = protectedDirectory.appendingPathComponent("keepalive")
        let ready = directory.appendingPathComponent("ready")
        try FileManager.default.createDirectory(at: sentinelParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        #expect(FileManager.default.createFile(atPath: keepalive.path, contents: Data()))
        #expect(FileManager.default.createFile(atPath: protectedKeepalive.path, contents: Data("protected".utf8)))

        let supervisor = Process()
        defer {
            if supervisor.isRunning {
                _ = Darwin.kill(supervisor.processIdentifier, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let trustedScript = """
        /usr/bin/printf '%s\n' ready > \(shellQuote(ready.path))
        trap '' TERM HUP
        exec /bin/sleep 8
        """
        supervisor.executableURL = URL(fileURLWithPath: "/bin/sh")
        supervisor.arguments = [
            "-c",
            PrivilegedRunner.makeSupervisedShellScript(
                trustedScript,
                keepalivePath: keepalive.path,
                timeout: 0.1,
                timeoutMarker: "__MACSWEEP_TEST_TIMEOUT__"
            )
        ]
        supervisor.standardOutput = FileHandle.nullDevice
        supervisor.standardError = FileHandle.nullDevice
        try supervisor.run()

        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            Issue.record("Supervisor command did not become ready")
            return
        }

        try FileManager.default.moveItem(at: sentinelParent, to: savedSentinelParent)
        try FileManager.default.createSymbolicLink(
            at: sentinelParent,
            withDestinationURL: protectedDirectory
        )

        let exitDeadline = Date().addingTimeInterval(5)
        while supervisor.isRunning, Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!supervisor.isRunning)
        #expect(FileManager.default.fileExists(atPath: protectedKeepalive.path))
        #expect(try Data(contentsOf: protectedKeepalive) == Data("protected".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func rootAnchorCleansStateAfterSupervisorDiesPostCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-admin-post-cancel-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let keepalive = directory.appendingPathComponent("keepalive")
        let ready = directory.appendingPathComponent("ready")
        let stateDirectoryFile = directory.appendingPathComponent("state-directory")
        #expect(FileManager.default.createFile(atPath: keepalive.path, contents: Data()))

        let supervisor = Process()
        var recordedStateDirectory: String?
        defer {
            if supervisor.isRunning {
                _ = Darwin.kill(supervisor.processIdentifier, SIGKILL)
            }
            if let recordedStateDirectory {
                try? FileManager.default.removeItem(atPath: recordedStateDirectory)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let trustedScript = """
        /usr/bin/printf '%s\n' "$state_dir" > \(shellQuote(stateDirectoryFile.path))
        /usr/bin/printf '%s\n' ready > \(shellQuote(ready.path))
        trap '' TERM HUP
        exec /bin/sleep 8
        """
        supervisor.executableURL = URL(fileURLWithPath: "/bin/sh")
        supervisor.arguments = [
            "-c",
            PrivilegedRunner.makeSupervisedShellScript(
                trustedScript,
                keepalivePath: keepalive.path,
                timeout: 30,
                timeoutMarker: "__MACSWEEP_TEST_TIMEOUT__"
            )
        ]
        supervisor.standardOutput = FileHandle.nullDevice
        supervisor.standardError = FileHandle.nullDevice
        try supervisor.run()

        let readyDeadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard FileManager.default.fileExists(atPath: ready.path),
              let statePath = try? String(contentsOf: stateDirectoryFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !statePath.isEmpty
        else {
            Issue.record("Supervisor command did not publish its root state directory")
            return
        }
        recordedStateDirectory = statePath
        #expect(FileManager.default.fileExists(atPath: statePath))

        #expect(Darwin.kill(supervisor.processIdentifier, SIGSTOP) == 0)
        try FileManager.default.removeItem(at: keepalive)
        #expect(Darwin.kill(supervisor.processIdentifier, SIGKILL) == 0)

        let supervisorExitDeadline = Date().addingTimeInterval(1)
        while supervisor.isRunning, Date() < supervisorExitDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!supervisor.isRunning)

        let cleanupDeadline = Date().addingTimeInterval(4)
        while FileManager.default.fileExists(atPath: statePath), Date() < cleanupDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!FileManager.default.fileExists(atPath: statePath))
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
