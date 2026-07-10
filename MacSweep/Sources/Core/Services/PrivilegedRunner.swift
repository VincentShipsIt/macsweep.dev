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
    static func runSupervisedShellScriptForTesting(
        _ script: String,
        timeout: TimeInterval,
        throughAppleScript: Bool = false
    ) async throws {
        guard isValid(timeout: timeout) else {
            throw EscalationError.failed(status: -1)
        }
        let sentinel = try makeCancellationSentinel()
        defer { try? FileManager.default.removeItem(at: sentinel.directory) }
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
                throw EscalationError.timedOut(partialResult: partialResult)
            case .launchFailed, .nonZeroExit:
                throw EscalationError.failed(status: -1)
            }
        } catch {
            throw EscalationError.failed(status: -1)
        }

        if let timeoutMarker,
           result.output.contains(timeoutMarker) || result.error.contains(timeoutMarker) {
            throw EscalationError.timedOut(partialResult: result)
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

    /// Builds a pure `/bin/sh` root supervisor. `set -m` gives the trusted command
    /// a PGID equal to its leader PID; the supervisor stays outside that group and
    /// can therefore enforce TERM/grace/KILL even when the app cannot signal root.
    /// Internal shell-construction seam used by lifecycle tests. Entry points
    /// validate `timeout` before calling this helper so tick conversion cannot
    /// trap on non-finite or out-of-range values.
    static func makeSupervisedShellScript(
        _ script: String,
        keepalivePath: String,
        timeout: TimeInterval,
        timeoutMarker: String
    ) -> String {
        // The keepalive removal enforces the caller's exact monotonic deadline.
        // This longer fallback bounds elevated work if the app crashes first.
        let fallbackTicks = max(1, Int(ceil((timeout + 2) * 10)))
        // Give a live outer supervisor one extra second to remove the keepalive
        // before the anchor treats a full fallback as an orphaned-supervisor path.
        let anchorFallbackTicks = fallbackTicks + 10
        let keepalive = shellQuote(keepalivePath)

        return """
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        umask 077
        state_dir=$(/usr/bin/mktemp -d /private/var/tmp/macsweep-admin.XXXXXX) || exit 125
        trap '/bin/rm -rf "$state_dir"' EXIT
        /bin/chmod 700 "$state_dir" || exit 125
        status_file="$state_dir/status"
        stdout_file="$state_dir/stdout"
        stderr_file="$state_dir/stderr"
        release_file="$state_dir/release"
        if [ ! -e \(keepalive) ]; then
          /usr/bin/printf '%s\n' '\(timeoutMarker)' >&2
          exit 124
        fi
        set -m
        (
          trap '' TERM HUP
          set +m
          terminate_group() {
            /bin/kill -TERM 0 2>/dev/null
            /bin/sleep 0.5
            if [ -e \(keepalive) ]; then
              /bin/rm -rf "$state_dir"
            fi
            /bin/kill -KILL 0 2>/dev/null
          }
          (
            trap - TERM HUP
            if [ -e \(keepalive) ]; then
              (
        \(script)
              )
              command_status=$?
            else
              command_status=124
            fi
            /usr/bin/printf '%s\n' "$command_status" >"$status_file"
            exit "$command_status"
          ) >"$stdout_file" 2>"$stderr_file" &
          anchor_tick=0
          while [ ! -s "$status_file" ] && [ -d "$state_dir" ] && [ -e \(keepalive) ] && [ "$anchor_tick" -lt \(anchorFallbackTicks) ]; do
            /bin/sleep 0.1
            anchor_tick=$((anchor_tick + 1))
          done
          if [ ! -e \(keepalive) ] || [ ! -d "$state_dir" ] || [ "$anchor_tick" -ge \(anchorFallbackTicks) ]; then
            terminate_group
          fi
          if [ -s "$status_file" ]; then
            IFS= read -r command_status <"$status_file"
          else
            command_status=124
          fi
          release_tick=0
          while [ ! -e "$release_file" ] && [ -d "$state_dir" ] && [ -e \(keepalive) ] && [ "$release_tick" -lt \(anchorFallbackTicks) ]; do
            /bin/sleep 0.1
            release_tick=$((release_tick + 1))
          done
          if [ ! -e "$release_file" ]; then
            terminate_group
          fi
          exit "$command_status"
        ) &
        set +m
        tick=0
        while [ ! -s "$status_file" ] && [ -e \(keepalive) ] && [ "$tick" -lt \(fallbackTicks) ]; do
          /bin/sleep 0.1
          tick=$((tick + 1))
        done
        if [ ! -e \(keepalive) ] || [ "$tick" -ge \(fallbackTicks) ]; then
          /bin/rm -f \(keepalive)
          /bin/sleep 0.7
          /bin/cat "$stdout_file" >&2
          /bin/cat "$stderr_file" >&2
          /usr/bin/printf '%s\n' '\(timeoutMarker)' >&2
          exit 124
        fi
        if [ -s "$status_file" ]; then
          IFS= read -r command_status <"$status_file"
          : >"$release_file"
          /bin/cat "$stdout_file"
          /bin/cat "$stderr_file" >&2
          exit "${command_status:-1}"
        fi
        /usr/bin/printf '%s\n' 'Supervisor state error' >&2
        exit 125
        """
    }

    private static func isValid(timeout: TimeInterval) -> Bool {
        timeout.isFinite && timeout >= 0 && timeout <= maximumTimeout
    }

    private static func makeTimeoutMarker() -> String {
        "__MACSWEEP_PRIVILEGED_TIMEOUT_\(UUID().uuidString)__"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
