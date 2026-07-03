import Foundation

/// Result of a completed subprocess, with stdout and stderr captured separately.
///
/// Keeping the two streams apart lets callers parse stdout without stderr noise —
/// e.g. Homebrew writes progress to stderr, so a merged stream would corrupt the
/// parsed output. Callers that genuinely want both can concatenate.
///
/// Canonical result type for `ProcessRunner`; shared across Core (also produced by
/// the not-yet-migrated `DevToolsModule.run`). `MalwareScannerService` keeps its
/// own tuple — it deliberately merges both streams into one pipe.
struct ProcessResult: Sendable {
    let status: Int32
    let output: String   // stdout
    let error: String    // stderr

    /// True when the process exited 0.
    var didSucceed: Bool { status == 0 }

    /// Returns `self` when the process exited 0; otherwise throws
    /// `ProcessRunnerError.nonZeroExit`. For call sites that prefer to treat a
    /// failed exit as an error rather than branch on `status`.
    @discardableResult
    func checkedSuccess() throws -> ProcessResult {
        guard status == 0 else {
            throw ProcessRunnerError.nonZeroExit(status: status, stderr: error)
        }
        return self
    }
}

/// Errors thrown by `ProcessRunner.run`.
enum ProcessRunnerError: Error, Sendable, CustomStringConvertible {
    /// The executable could not be launched (bad path, permissions, …).
    case launchFailed(String)
    /// The process was still running after `timeout` seconds and was terminated.
    case timedOut(after: TimeInterval)
    /// Only thrown by `ProcessResult.checkedSuccess()` — the process exited non-zero.
    case nonZeroExit(status: Int32, stderr: String)

    var description: String {
        switch self {
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        case .timedOut(let timeout): return "Process timed out after \(timeout)s"
        case .nonZeroExit(let status, _): return "Process exited with status \(status)"
        }
    }
}

/// The single argv-only subprocess runner for Core.
///
/// Every call:
///  * launches the executable with an explicit argument vector — **never**
///    `/bin/bash -c`, so an argument can never be reinterpreted as shell syntax;
///  * drains stdout and stderr **concurrently** on separate threads, so neither
///    pipe's ~64 KB buffer can fill and wedge the child before it exits (the
///    classic two-pipe deadlock);
///  * enforces a **watchdog timeout** (default 10 s) that terminates a stuck child
///    so `waitUntilExit()` can never block a caller forever;
///  * keeps stdout and stderr **separate** in the result.
///
/// Replaces the family of hand-rolled `Process()` sites across Core, only one of
/// which previously had a timeout.
enum ProcessRunner {
    /// Runs `executable` with `arguments` and returns its captured output.
    ///
    /// - Throws: `ProcessRunnerError.launchFailed` if the process can't start, or
    ///   `.timedOut` if it outlives `timeout`. A completed process that exits
    ///   non-zero is returned as a `ProcessResult` (inspect `status`) — use
    ///   `ProcessResult.checkedSuccess()` if you'd rather that throw.
    static func run(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 10
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    return
                }

                // Watchdog: terminate a child still alive past the deadline. The
                // flag records that WE killed it, so a timeout is reported as such
                // rather than as whatever exit status SIGTERM happens to produce.
                let timeoutLock = NSLock()
                var didTimeout = false
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timeoutLock.lock(); didTimeout = true; timeoutLock.unlock()
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

                // Drain stderr on its own thread while stdout drains here, so a
                // chatty command can't block on a full pipe buffer before it exits.
                let stderrHandle = stderrPipe.fileHandleForReading
                let stderrQueue = DispatchQueue(label: "macsweep.processrunner.stderr")
                var stderrData = Data()
                stderrQueue.async { stderrData = stderrHandle.readDataToEndOfFile() }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                stderrQueue.sync {}   // ensure the stderr drain has finished

                timeoutLock.lock(); let timedOut = didTimeout; timeoutLock.unlock()
                if timedOut {
                    continuation.resume(throwing: ProcessRunnerError.timedOut(after: timeout))
                    return
                }

                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    output: String(data: stdoutData, encoding: .utf8) ?? "",
                    error: String(data: stderrData, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
