import Foundation

/// The single, deliberate privilege-escalation point in MacSweep.
///
/// Everything else runs unprivileged through `ProcessRunner` with an explicit
/// argv. This helper is the ONE sanctioned exception: it runs a shell script *as
/// administrator* via `osascript`'s `do shell script … with administrator
/// privileges`, which shows the system authorization prompt and executes the
/// script through a shell as root.
///
/// It is intentionally **not** built on `ProcessRunner`:
///  * `do shell script` is shell-interpreted by design — the exact opposite of
///    ProcessRunner's argv-only guarantee. Routing it through the same API would
///    hide a root shell behind a "safe" front door.
///  * Privilege escalation deserves a single, named, auditable choke point, not
///    one anonymous `Process()` among dozens.
///
/// Because the script is shell-interpreted and runs as root, callers MUST pass
/// only trusted, hard-coded command strings — never anything derived from scanned
/// files, network responses, or other untrusted input.
enum PrivilegedRunner {
    enum EscalationError: LocalizedError {
        case failed(status: Int32)
        case timedOut

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
    ///     caller forever.
    /// - Throws: `EscalationError.failed` if the user declines or the script exits
    ///   non-zero; `EscalationError.timedOut` if it outlives `timeout`.
    static func runShellScriptAsAdmin(_ script: String, timeout: TimeInterval = 120) async throws {
        // `osascript -e` itself is a normal argv launch; the shell interpretation
        // happens inside AppleScript's `do shell script`. Escaping is deliberately
        // minimal — callers contract to pass only constant, trusted scripts.
        let appleScript = "do shell script \"\(script)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw EscalationError.failed(status: -1)
        }

        // Bounded wait: terminate a stuck osascript rather than block forever.
        let deadline = DispatchTime.now() + timeout
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: watchdog)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                watchdog.cancel()
                continuation.resume()
            }
        }

        guard process.terminationStatus == 0 else {
            throw EscalationError.failed(status: process.terminationStatus)
        }
    }
}
