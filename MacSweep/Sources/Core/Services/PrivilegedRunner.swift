import Foundation
import Darwin

/// The single, deliberate privilege-escalation point in MacSweep.
///
/// Everything else runs unprivileged through `ProcessRunner` with an explicit
/// argv. This helper is the ONE sanctioned exception: it runs a shell script *as
/// administrator* via `osascript`'s `do shell script … with administrator
/// privileges`, which shows the system authorization prompt and executes the
/// script through a shell as root.
///
/// It remains a separate named API because `do shell script` is shell-interpreted
/// by design — the exact opposite of `ProcessRunner`'s argv-only caller contract.
/// Only the ordinary `osascript` wrapper launch delegates to `ProcessRunner`, so
/// privilege escalation keeps one auditable choke point while sharing the bounded
/// process-group and output lifecycle.
///
/// Because the script is shell-interpreted and runs as root, callers MUST pass
/// only trusted, hard-coded command strings — never anything derived from scanned
/// files, network responses, or other untrusted input. Scripts must remain
/// synchronous: they must not daemonize, start intentional background work, or
/// escape the supervised process group/session. The current DNS flush satisfies
/// that contract; a true long-running helper would require a dedicated protocol.
/// Secure root-side output capture is intentionally uncapped, matching
/// ProcessRunner's existing capture semantics, so this boundary is for short
/// administrative commands rather than high-volume streaming work.
enum PrivilegedRunner {
    private static let rootCleanupGrace: TimeInterval = 1.5
    private static let maximumTimeout: TimeInterval = 31_536_000

    enum EscalationError: LocalizedError {
        case failed(status: Int32)
        /// Carries bytes emitted before the watchdog escalated. This is an
        /// intentional enrichment of the previous payload-free timeout case.
        case timedOut(partialResult: ProcessResult)

        var errorDescription: String? {
            switch self {
            case .failed: return "Administrator command failed or was declined"
            case .timedOut: return "Administrator command timed out"
            }
        }
    }

    /// Runs a **trusted, hard-coded** shell script with administrator privileges,
    /// prompting the user for authorization.
    ///
    /// - Parameters:
    ///   - script: a constant command string. Do NOT interpolate untrusted values
    ///     into it — it is evaluated by a shell as root.
    ///   - timeout: watchdog ceiling. Generous by default because the auth prompt
    ///     is user-paced, but still bounded so a wedged `osascript` can't hang the
    ///     caller forever. Must be finite and between zero and one year.
    /// - Throws: `EscalationError.failed` if the user declines or the script exits
    ///   non-zero; `EscalationError.timedOut` if it outlives `timeout`.
    static func runShellScriptAsAdmin(_ script: String, timeout: TimeInterval = 120) async throws {
        try await runTrustedAdminScript(script, timeout: timeout)
    }

    /// Internal executor used only by constant scripts or the finite validated
    /// action builders. Filesystem/command data must never become shell code.
    static func runTrustedAdminScript(_ script: String, timeout: TimeInterval) async throws {
        guard isValid(timeout: timeout) else {
            throw EscalationError.failed(status: -1)
        }
        let sentinel: CancellationSentinel
        do {
            sentinel = try makeCancellationSentinel()
        } catch {
            throw EscalationError.failed(status: -1)
        }
        defer { try? FileManager.default.removeItem(at: sentinel.directory) }

        // The root shell supervises the trusted command in a separate process
        // group. The unprivileged watchdog removes `keepalive` at its monotonic
        // deadline; the root supervisor then owns TERM/grace/KILL for elevated
        // descendants that the app process has no permission to signal.
        let timeoutMarker = makeTimeoutMarker()
        let supervisedScript = makeSupervisedShellScript(
            script,
            keepalivePath: sentinel.keepalive.path,
            timeout: timeout,
            timeoutMarker: timeoutMarker
        )
        let appleScript = "do shell script \(appleScriptLiteral(supervisedScript)) with administrator privileges"

        try await run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", appleScript],
            timeout: timeout,
            timeoutCancellationFile: sentinel.keepalive.path,
            cooperativeTimeoutGrace: rootCleanupGrace,
            timeoutMarker: timeoutMarker
        )
    }

    /// Exercises the exact root-supervisor shell without authorization UI. The
    /// command runs as the test user, but process-group and timeout behavior is
    /// identical to the elevated shell path.
    ///
    /// `keepaliveForTesting`, when provided, lets a test pre-create and own the
    /// cancellation keepalive so it can drive the timeout *deterministically* —
    /// removing the file only after the child has provably emitted its output —
    /// instead of racing a wall-clock deadline against process startup latency.
    /// This mirrors `ProcessRunner`'s real pre-created keepalive seam. When nil,
    /// behavior is unchanged: a fresh sentinel is created and owned internally.
    static func runSupervisedShellScriptForTesting(
        _ script: String,
        timeout: TimeInterval,
        throughAppleScript: Bool = false,
        keepaliveForTesting: URL? = nil
    ) async throws {
        guard isValid(timeout: timeout) else {
            throw EscalationError.failed(status: -1)
        }
        let sentinel: CancellationSentinel
        let ownsSentinelDirectory: Bool
        if let keepaliveForTesting {
            sentinel = CancellationSentinel(
                directory: keepaliveForTesting.deletingLastPathComponent(),
                keepalive: keepaliveForTesting
            )
            ownsSentinelDirectory = false
        } else {
            sentinel = try makeCancellationSentinel()
            ownsSentinelDirectory = true
        }
        defer {
            if ownsSentinelDirectory {
                try? FileManager.default.removeItem(at: sentinel.directory)
            }
        }
        let timeoutMarker = makeTimeoutMarker()
        let supervisedScript = makeSupervisedShellScript(
            script,
            keepalivePath: sentinel.keepalive.path,
            timeout: timeout,
            timeoutMarker: timeoutMarker
        )
        let executable: String
        let arguments: [String]
        if throughAppleScript {
            executable = "/usr/bin/osascript"
            arguments = ["-e", "do shell script \(appleScriptLiteral(supervisedScript))"]
        } else {
            executable = "/bin/sh"
            arguments = ["-c", supervisedScript]
        }
        try await run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            timeoutCancellationFile: sentinel.keepalive.path,
            cooperativeTimeoutGrace: rootCleanupGrace,
            timeoutMarker: timeoutMarker
        )
    }

    /// Internal invocation seam used by deterministic tests without displaying an
    /// authorization prompt. The named public-facing method above remains the only
    /// place that constructs a privileged AppleScript.
    static func run(
        executable: String,
        arguments: [String] = [],
        timeout: TimeInterval,
        timeoutCancellationFile: String? = nil,
        cooperativeTimeoutGrace: TimeInterval = 0,
        timeoutMarker: String? = nil
    ) async throws {
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                timeoutCancellationFile: timeoutCancellationFile,
                cooperativeTimeoutGrace: cooperativeTimeoutGrace
            )
        } catch let runnerError as ProcessRunnerError {
            switch runnerError {
            case .timedOut(_, let partialResult):
                let normalizedResult = timeoutMarker.map {
                    normalizedTimeoutResult(partialResult, timeoutMarker: $0)
                } ?? partialResult
                throw EscalationError.timedOut(partialResult: normalizedResult)
            case .launchFailed, .nonZeroExit:
                throw EscalationError.failed(status: -1)
            }
        } catch {
            throw EscalationError.failed(status: -1)
        }

        if let timeoutMarker,
           result.output.contains(timeoutMarker) || result.error.contains(timeoutMarker) {
            throw EscalationError.timedOut(
                partialResult: normalizedTimeoutResult(result, timeoutMarker: timeoutMarker)
            )
        }
        guard result.status == 0 else {
            throw EscalationError.failed(status: result.status)
        }
    }

    private struct CancellationSentinel {
        let directory: URL
        let keepalive: URL
    }

    private static func makeCancellationSentinel() throws -> CancellationSentinel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-admin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let keepalive = directory.appendingPathComponent("keepalive")
        guard FileManager.default.createFile(
            atPath: keepalive.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
        return CancellationSentinel(directory: directory, keepalive: keepalive)
    }

    private static func isValid(timeout: TimeInterval) -> Bool {
        timeout.isFinite && timeout >= 0 && timeout <= maximumTimeout
    }

    private static func makeTimeoutMarker() -> String {
        "__MACSWEEP_PRIVILEGED_TIMEOUT_\(UUID().uuidString)__"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
