import Testing
import Foundation
import Darwin
@testable import MacSweepCore

struct PrivilegedTimeoutNormalizationTests {
    @Test(.timeLimit(.minutes(1)))
    func captureDescriptorsSurviveDelayedTimeoutReader() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-pinned-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let keepalive = directory.appendingPathComponent("keepalive")
        let ready = directory.appendingPathComponent("ready")
        let stateDirectoryFile = directory.appendingPathComponent("state-directory")
        #expect(FileManager.default.createFile(atPath: keepalive.path, contents: Data()))

        let (stdout, stderr) = (Pipe(), Pipe())
        let supervisor = makeSupervisor(
            keepalive: keepalive,
            ready: ready,
            stateDirectoryFile: stateDirectoryFile,
            stdout: stdout,
            stderr: stderr
        )
        defer {
            cleanup(supervisor: supervisor, keepalive: keepalive, directory: directory)
        }

        try supervisor.run()

        try await waitForFile(at: ready, exists: true, timeout: 3)
        guard FileManager.default.fileExists(atPath: ready.path) else {
            Issue.record("Supervisor command did not become ready")
            return
        }
        let stateDirectory = try recordedPath(from: stateDirectoryFile)
        #expect(FileManager.default.fileExists(atPath: stateDirectory.path))

        // Freeze only the outer reader. The independent anchor observes
        // cancellation and unlinks state before the reader resumes. Pre-pinned
        // descriptors must still expose both files.
        #expect(Darwin.kill(supervisor.processIdentifier, SIGSTOP) == 0)
        try FileManager.default.removeItem(at: keepalive)
        try await waitForFile(
            at: stateDirectory,
            exists: false,
            timeout: 5
        )
        #expect(!FileManager.default.fileExists(atPath: stateDirectory.path))
        #expect(Darwin.kill(supervisor.processIdentifier, SIGCONT) == 0)

        let exitDeadline = Date().addingTimeInterval(5)
        while supervisor.isRunning, Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !supervisor.isRunning else {
            Issue.record("Supervisor did not exit after timeout reader resumed")
            return
        }

        let output = try readUTF8(from: stdout) + readUTF8(from: stderr)
        #expect(output.contains("pinned stdout"))
        #expect(output.contains("pinned stderr"))
    }

    @Test func normalizesObservedAppleScriptTimeoutWrapper() {
        let marker = "__MACSWEEP_PRIVILEGED_TIMEOUT_TEST__"
        let result = ProcessResult(
            status: 1,
            output: "",
            error: "0:4627: execution error: first line\rsecond line\r\(marker) (124)\n"
        )

        let normalized = PrivilegedRunner.normalizedTimeoutResult(
            result,
            timeoutMarker: marker
        )

        #expect(normalized.output.isEmpty)
        #expect(normalized.error == "first line\nsecond line")
    }

    @Test func removesDirectTimeoutMarkerWithoutChangingOtherStreams() {
        let marker = "__MACSWEEP_PRIVILEGED_TIMEOUT_TEST__"
        let result = ProcessResult(
            status: 124,
            output: "ordinary stdout\n",
            error: "ordinary stderr\n\(marker)\n"
        )

        let normalized = PrivilegedRunner.normalizedTimeoutResult(
            result,
            timeoutMarker: marker
        )

        #expect(normalized.output == "ordinary stdout\n")
        #expect(normalized.error == "ordinary stderr\n")
    }

    private func makeSupervisor(
        keepalive: URL,
        ready: URL,
        stateDirectoryFile: URL,
        stdout: Pipe,
        stderr: Pipe
    ) -> Process {
        let trustedScript = """
        /usr/bin/printf '%s\n' "$state_dir" > \(shellQuote(stateDirectoryFile.path))
        /usr/bin/printf '%s\n' 'pinned stdout'
        /usr/bin/printf '%s\n' 'pinned stderr' >&2
        /usr/bin/printf '%s\n' ready > \(shellQuote(ready.path))
        trap '' TERM HUP
        exec /bin/sleep 120
        """
        let supervisor = Process()
        supervisor.executableURL = URL(fileURLWithPath: "/bin/sh")
        supervisor.arguments = [
            "-c",
            PrivilegedRunner.makeSupervisedShellScript(
                trustedScript,
                keepalivePath: keepalive.path,
                timeout: 20,
                timeoutMarker: "__MACSWEEP_TEST_TIMEOUT__"
            )
        ]
        supervisor.standardOutput = stdout
        supervisor.standardError = stderr
        return supervisor
    }

    private func cleanup(supervisor: Process, keepalive: URL, directory: URL) {
        _ = keepalive.path.withCString(Darwin.unlink)
        if supervisor.isRunning {
            _ = Darwin.kill(supervisor.processIdentifier, SIGCONT)
            _ = Darwin.kill(supervisor.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func readUTF8(from pipe: Pipe) throws -> String {
        try #require(
            String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )
        )
    }

    private func recordedPath(from file: URL) throws -> URL {
        let path = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path)
    }

    private func waitForFile(at url: URL, exists: Bool, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while FileManager.default.fileExists(atPath: url.path) != exists, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
