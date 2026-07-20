import Foundation
import Darwin

enum ProcessOutputStream: Sendable {
    case standardOutput
    case standardError
}

typealias ProcessOutputHandler = @Sendable (
    _ stream: ProcessOutputStream,
    _ chunk: Data
) -> Void

/// Result of a completed subprocess, with stdout and stderr captured separately.
///
/// Keeping the two streams apart lets callers parse stdout without stderr noise —
/// e.g. Homebrew writes progress to stderr, so a merged stream would corrupt the
/// parsed output. Callers that genuinely want both can concatenate.
struct ProcessResult: Sendable {
    let status: Int32
    let output: String   // stdout
    let error: String    // stderr
    /// Whether the captured stdout bytes were valid UTF-8. Deletion guards that
    /// consume NUL-delimited paths use this to fail closed on undecodable bytes.
    let outputWasValidUTF8: Bool

    init(
        status: Int32,
        output: String,
        error: String,
        outputWasValidUTF8: Bool = true
    ) {
        self.status = status
        self.output = output
        self.error = error
        self.outputWasValidUTF8 = outputWasValidUTF8
    }

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
    /// The process lifecycle exceeded `timeout`. Output captured before the hard
    /// deadline is retained for diagnostics instead of being discarded.
    case timedOut(after: TimeInterval, partialResult: ProcessResult)
    /// Only thrown by `ProcessResult.checkedSuccess()` — the process exited non-zero.
    case nonZeroExit(status: Int32, stderr: String)

    var description: String {
        switch self {
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        case .timedOut(let timeout, _): return "Process timed out after \(timeout)s"
        case .nonZeroExit(let status, _): return "Process exited with status \(status)"
        }
    }
}

/// The single argv-only subprocess runner for Core.
///
/// Every call:
///  * launches the executable with an explicit argument vector — **never**
///    `/bin/bash -c`, so an argument can never be reinterpreted as shell syntax;
///  * atomically places the child in a new process group with `posix_spawn`, so a
///    timeout can terminate ordinary descendants without a post-exec `setpgid` race;
///  * drains stdout and stderr concurrently from launch on nonblocking descriptors;
///  * bounds the complete lifecycle, including EOF when descendants inherited the
///    capture descriptors: SIGTERM to the group, a grace period, then SIGKILL and
///    forced drain cancellation;
///  * keeps stdout and stderr separate and preserves partial bytes on timeout.
enum ProcessRunner {
    private static let terminationGrace: TimeInterval = 0.5
    private static let forcedCleanupGrace: TimeInterval = 0.5
    private static let drainPollMilliseconds: Int32 = 20
    private static let maximumTimeout: TimeInterval = 31_536_000

    private struct RunOptions {
        let currentDirectory: URL?
        let timeout: TimeInterval
        let timeoutCancellationFile: String?
        let cooperativeTimeoutGrace: TimeInterval
        let onOutput: ProcessOutputHandler?
    }

    /// Runs `executable` with `arguments` and returns its captured output.
    ///
    /// Existing call sites and successful/nonzero result behavior remain source
    /// compatible. The timeout error intentionally now carries a partial result.
    /// `timeoutCancellationFile` and `cooperativeTimeoutGrace` are a restricted
    /// internal hook for PrivilegedRunner's pre-created local keepalive; ordinary
    /// callers should leave both at their defaults. Cooperative grace extends the
    /// total hard bound by at most that value before TERM/grace/KILL begins.
    ///
    /// Resource boundaries intentionally unchanged in this focused patch:
    /// captured output is memory-unbounded, and Swift task cancellation does not
    /// preempt the child—it completes at the configured process timeout. stdin is
    /// inherited for noninteractive commands, but terminal reads are unsupported
    /// because the child runs in a background process group and may receive SIGTTIN.
    /// - Throws: `ProcessRunnerError.launchFailed` if the process can't start, or
    ///   `.timedOut` if the full process/output lifecycle outlives `timeout`. A
    ///   completed process that exits non-zero is returned as a `ProcessResult`
    ///   (inspect `status`) — use `checkedSuccess()` if you'd rather that throw.
    static func run(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 10,
        timeoutCancellationFile: String? = nil,
        cooperativeTimeoutGrace: TimeInterval = 0
    ) async throws -> ProcessResult {
        try await execute(
            executable: executable,
            arguments: arguments,
            options: RunOptions(
                currentDirectory: currentDirectory,
                timeout: timeout,
                timeoutCancellationFile: timeoutCancellationFile,
                cooperativeTimeoutGrace: cooperativeTimeoutGrace,
                onOutput: nil
            )
        )
    }

    /// Runs a bounded process while reporting incremental stdout and stderr.
    ///
    /// `onOutput` is called from the two drain queues and may therefore be invoked
    /// concurrently. Handlers must return promptly; the full captured result remains
    /// authoritative even when callers also consume incremental chunks.
    static func runStreaming(
        executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 10,
        onOutput: @escaping ProcessOutputHandler
    ) async throws -> ProcessResult {
        try await execute(
            executable: executable,
            arguments: arguments,
            options: RunOptions(
                currentDirectory: currentDirectory,
                timeout: timeout,
                timeoutCancellationFile: nil,
                cooperativeTimeoutGrace: 0,
                onOutput: onOutput
            )
        )
    }

    private static func execute(
        executable: String,
        arguments: [String],
        options: RunOptions
    ) async throws -> ProcessResult {
        guard options.timeout.isFinite,
              options.timeout >= 0,
              options.timeout <= maximumTimeout,
              options.cooperativeTimeoutGrace.isFinite,
              options.cooperativeTimeoutGrace >= 0,
              options.cooperativeTimeoutGrace <= maximumTimeout
        else {
            throw ProcessRunnerError.launchFailed(
                "Timeout values must be finite and between 0 and \(maximumTimeout) seconds"
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runSynchronously(
                        executable: executable,
                        arguments: arguments,
                        options: options
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        options: RunOptions
    ) throws -> ProcessResult {
        var stdoutPipe = try makePipe()
        var stderrPipe: PipeDescriptors
        do {
            stderrPipe = try makePipe()
        } catch {
            closeDescriptor(stdoutPipe.read)
            closeDescriptor(stdoutPipe.write)
            throw error
        }

        // Until ownership is transferred to the drain workers, every descriptor
        // is closed by this scope on every setup/launch failure path.
        defer {
            closeDescriptor(stdoutPipe.read)
            closeDescriptor(stdoutPipe.write)
            closeDescriptor(stderrPipe.read)
            closeDescriptor(stderrPipe.write)
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checkSpawnSetup(posix_spawn_file_actions_init(&fileActions), operation: "initialize file actions")
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try checkSpawnSetup(posix_spawnattr_init(&attributes), operation: "initialize spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }

        // CLOEXEC_DEFAULT avoids leaking unrelated application descriptors into
        // the child. stdin is explicitly inherited for existing noninteractive
        // callers; interactive terminal reads are unsupported in the new pgroup.
        // stdout/stderr are replaced by the capture pipes.
        let stdinFlags = fcntl(STDIN_FILENO, F_GETFD)
        if stdinFlags >= 0 {
            try checkSpawnSetup(
                posix_spawn_file_actions_addinherit_np(&fileActions, STDIN_FILENO),
                operation: "inherit stdin"
            )
        } else if errno != EBADF {
            throw ProcessRunnerError.launchFailed("Could not inspect stdin: \(errorMessage(for: errno))")
        }
        try checkSpawnSetup(
            posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO),
            operation: "redirect stdout"
        )
        try checkSpawnSetup(
            posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO),
            operation: "redirect stderr"
        )
        for descriptor in [stdoutPipe.read, stdoutPipe.write, stderrPipe.read, stderrPipe.write] {
            try checkSpawnSetup(
                posix_spawn_file_actions_addclose(&fileActions, descriptor),
                operation: "close child pipe descriptor"
            )
        }
        if let currentDirectory = options.currentDirectory {
            let directoryStatus = currentDirectory.path.withCString {
                posix_spawn_file_actions_addchdir(&fileActions, $0)
            }
            try checkSpawnSetup(directoryStatus, operation: "set current directory")
        }

        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try checkSpawnSetup(
            posix_spawnattr_setflags(&attributes, spawnFlags),
            operation: "set process-group flags"
        )
        // A pgroup value of zero makes the spawned child the leader of a new group.
        try checkSpawnSetup(
            posix_spawnattr_setpgroup(&attributes, 0),
            operation: "create process group"
        )

        var argv = try makeCStringArray([executable] + arguments)
        defer { freeCStringArray(argv) }

        var childPID: pid_t = 0
        let spawnStatus = executable.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                posix_spawn(
                    &childPID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argvBuffer.baseAddress!,
                    environ
                )
            }
        }
        guard spawnStatus == 0 else {
            throw ProcessRunnerError.launchFailed(errorMessage(for: spawnStatus))
        }

        // The child has its own copies; closing the parent's write ends is required
        // for EOF to mean that the spawned group actually closed its writers.
        closeDescriptor(stdoutPipe.write)
        stdoutPipe.write = -1
        closeDescriptor(stderrPipe.write)
        stderrPipe.write = -1

        // POSIX_SPAWN_SETPGROUP with pgroup 0 establishes PGID == childPID
        // atomically before execution. Keep the leader unreaped until completion
        // or timeout so that numeric PID/PGID cannot be reused underneath us.
        guard childPID > 1 else {
            throw ProcessRunnerError.launchFailed("posix_spawn returned an invalid process identifier")
        }

        let stdoutBuffer = LockedBuffer()
        let stderrBuffer = LockedBuffer()
        let drainCancellation = CancellationFlag()
        let drains = DispatchGroup()

        let stdoutRead = stdoutPipe.read
        stdoutPipe.read = -1
        startDrain(
            target: DrainTarget(
                descriptor: stdoutRead,
                stream: .standardOutput,
                buffer: stdoutBuffer
            ),
            cancellation: drainCancellation,
            group: drains,
            onOutput: options.onOutput
        )
        let stderrRead = stderrPipe.read
        stderrPipe.read = -1
        startDrain(
            target: DrainTarget(
                descriptor: stderrRead,
                stream: .standardError,
                buffer: stderrBuffer
            ),
            cancellation: drainCancellation,
            group: drains,
            onOutput: options.onOutput
        )

        let lifecycleDeadline = DispatchTime.now() + options.timeout
        if drains.wait(timeout: lifecycleDeadline) == .success,
           let rawStatus = waitForChild(childPID, until: lifecycleDeadline) {
            let stdout = stdoutBuffer.decodedUTF8
            let stderr = stderrBuffer.decodedUTF8
            return ProcessResult(
                status: terminationStatus(from: rawStatus),
                output: stdout.string,
                error: stderr.string,
                outputWasValidUTF8: stdout.wasValid
            )
        }

        // Timeout covers both the direct process and pipe EOF. The leader is not
        // reaped before this point, keeping its PID/PGID reserved while inherited
        // descriptors may still be open in descendants.
        if let timeoutCancellationFile = options.timeoutCancellationFile {
            // PrivilegedRunner's pre-created keepalive lives on the local temp
            // volume. Removing it is the only cooperative callback supported here;
            // arbitrary caller code could block and weaken the lifecycle bound.
            _ = timeoutCancellationFile.withCString { Darwin.unlink($0) }
        }

        // PrivilegedRunner uses this bounded window for its root-side supervisor
        // to observe cancellation, terminate the elevated command group, and flush
        // securely captured partial output before the unprivileged wrapper dies.
        if options.cooperativeTimeoutGrace > 0 {
            let cooperativeDeadline = DispatchTime.now() + options.cooperativeTimeoutGrace
            if drains.wait(timeout: cooperativeDeadline) == .success,
               let rawStatus = waitForChild(childPID, until: cooperativeDeadline) {
                let stdout = stdoutBuffer.decodedUTF8
                let stderr = stderrBuffer.decodedUTF8
                let partial = ProcessResult(
                    status: terminationStatus(from: rawStatus),
                    output: stdout.string,
                    error: stderr.string,
                    outputWasValidUTF8: stdout.wasValid
                )
                throw ProcessRunnerError.timedOut(after: options.timeout, partialResult: partial)
            }
        }

        signalIsolatedGroup(childPID, signal: SIGTERM)
        let termDeadline = DispatchTime.now() + terminationGrace
        _ = waitForGroupToDisappear(childPID, until: termDeadline)

        // Always hard-kill both targets after grace. The leader may have moved
        // out of the original group, making the group probe return ESRCH even
        // though the still-reserved positive PID remains alive.
        signalIsolatedGroup(childPID, signal: SIGKILL)

        let cleanupDeadline = DispatchTime.now() + forcedCleanupGrace
        let rawStatus = waitForChild(childPID, until: cleanupDeadline)
        if drains.wait(timeout: cleanupDeadline) != .success {
            // An escaped descendant may still own a duplicate writer. Nonblocking
            // drains observe this flag within one short poll and close their own
            // read descriptors, so EOF can never hold this call indefinitely.
            drainCancellation.cancel()
            _ = drains.wait(timeout: DispatchTime.now() + 0.2)
        }

        if rawStatus == nil {
            // SIGKILL should make waitpid immediately reapable. Keep every wait
            // bounded even under a kernel/runtime anomaly; a process source reaps
            // a later exit without parking a utility thread indefinitely.
            DeferredReaper.schedule(childPID)
        }

        let stdout = stdoutBuffer.decodedUTF8
        let stderr = stderrBuffer.decodedUTF8
        let partial = ProcessResult(
            status: rawStatus.map(terminationStatus(from:)) ?? -1,
            output: stdout.string,
            error: stderr.string,
            outputWasValidUTF8: stdout.wasValid
        )
        throw ProcessRunnerError.timedOut(after: options.timeout, partialResult: partial)
    }

    private struct PipeDescriptors {
        var read: Int32
        var write: Int32
    }

    private struct DrainTarget {
        let descriptor: Int32
        let stream: ProcessOutputStream
        let buffer: LockedBuffer
    }

    private final class LockedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var decodedUTF8: (string: String, wasValid: Bool) {
            lock.lock()
            let snapshot = data
            lock.unlock()
            let decoded = String(bytes: snapshot, encoding: .utf8)
            return (decoded ?? "", decoded != nil)
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
        }
    }

    /// Retains a process-exit dispatch source until the child becomes reapable.
    /// This is used only after the bounded WNOHANG cleanup window is exhausted.
    private final class DeferredReaper: @unchecked Sendable {
        private var source: DispatchSourceProcess?

        static func schedule(_ pid: pid_t) {
            _ = DeferredReaper(pid: pid)
        }

        private init(pid: pid_t) {
            let processSource = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: DispatchQueue.global(qos: .utility)
            )
            source = processSource
            processSource.setEventHandler { [self] in
                var rawStatus: Int32 = 0
                let waitStatus = Darwin.waitpid(pid, &rawStatus, WNOHANG)
                let shouldRetry = waitStatus == 0 || (waitStatus == -1 && errno == EINTR)
                source?.cancel()
                source = nil
                if shouldRetry {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.01) {
                        DeferredReaper.schedule(pid)
                    }
                }
            }
            processSource.resume()
        }
    }

    private static func makePipe() throws -> PipeDescriptors {
        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeStatus = descriptors.withUnsafeMutableBufferPointer {
            Darwin.pipe($0.baseAddress!)
        }
        guard pipeStatus == 0 else {
            throw ProcessRunnerError.launchFailed(errorMessage(for: errno))
        }

        do {
            // If the host closed a standard descriptor, pipe() may reuse 0, 1,
            // or 2. Relocate those ends before adding dup/close spawn actions so
            // closing the originals cannot accidentally close captured stdout.
            for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
                let original = descriptors[index]
                let relocated = fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
                guard relocated >= 0 else {
                    throw ProcessRunnerError.launchFailed(errorMessage(for: errno))
                }
                closeDescriptor(original)
                descriptors[index] = relocated
            }
            for descriptor in descriptors {
                let descriptorFlags = fcntl(descriptor, F_GETFD)
                guard descriptorFlags >= 0,
                      fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
                else {
                    throw ProcessRunnerError.launchFailed(errorMessage(for: errno))
                }
            }
            let statusFlags = fcntl(descriptors[0], F_GETFL)
            guard statusFlags >= 0,
                  fcntl(descriptors[0], F_SETFL, statusFlags | O_NONBLOCK) == 0
            else {
                throw ProcessRunnerError.launchFailed(errorMessage(for: errno))
            }
        } catch {
            closeDescriptor(descriptors[0])
            closeDescriptor(descriptors[1])
            throw error
        }
        return PipeDescriptors(read: descriptors[0], write: descriptors[1])
    }

    private static func startDrain(
        target: DrainTarget,
        cancellation: CancellationFlag,
        group: DispatchGroup,
        onOutput: ProcessOutputHandler?
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                closeDescriptor(target.descriptor)
                group.leave()
            }

            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                // Check before every read, not only after EAGAIN. An escaped
                // descendant can keep the pipe perpetually readable; without
                // this check the post-timeout worker would append forever.
                if cancellation.isCancelled { return }
                let count = bytes.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(target.descriptor, rawBuffer.baseAddress!, rawBuffer.count)
                }
                if count > 0 {
                    let chunk = Data(bytes.prefix(Int(count)))
                    target.buffer.append(chunk)
                    onOutput?(target.stream, chunk)
                    continue
                }
                if count == 0 { return }
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { return }

                var pollDescriptor = pollfd(
                    fd: target.descriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollStatus = Darwin.poll(&pollDescriptor, 1, drainPollMilliseconds)
                if pollStatus < 0 && errno != EINTR { return }
            }
        }
    }

    /// Polls `waitpid` without ever extending past the supplied deadline. Calling
    /// this only after both drains complete or timeout keeps an exited leader
    /// unreaped (and its PID reserved) while descendants may retain pipe writers.
    private static func waitForChild(_ pid: pid_t, until deadline: DispatchTime) -> Int32? {
        while true {
            // Check before waitpid so even a stream of EINTR retries cannot carry
            // this polling loop beyond its monotonic hard deadline.
            guard DispatchTime.now() < deadline else { return nil }
            var rawStatus: Int32 = 0
            let waitStatus = Darwin.waitpid(pid, &rawStatus, WNOHANG)
            if waitStatus == pid { return rawStatus }
            if waitStatus == -1 {
                if errno == EINTR { continue }
                return nil
            }
            usleep(10_000)
        }
    }

    /// Narrow test seam proving an already-expired deadline returns before any
    /// waitpid retry. Production lifecycle code calls the private helper above.
    static func waitForChildForTesting(_ pid: pid_t, until deadline: DispatchTime) -> Int32? {
        waitForChild(pid, until: deadline)
    }

    private static func waitForGroupToDisappear(_ processGroup: pid_t, until deadline: DispatchTime) -> Bool {
        while true {
            guard DispatchTime.now() < deadline else { return false }
            guard processGroupExists(processGroup) else { return true }
            usleep(10_000)
        }
    }

    private static func processGroupExists(_ processGroup: pid_t) -> Bool {
        guard processGroup > 1, processGroup != getpgrp() else { return false }
        if Darwin.kill(-processGroup, 0) == 0 { return true }
        return errno == EPERM || errno == EINTR
    }

    private static func signalIsolatedGroup(_ processGroup: pid_t, signal: Int32) {
        guard processGroup > 1, processGroup != getpgrp() else { return }
        _ = Darwin.kill(-processGroup, signal)

        // Always signal the direct leader too. It may have moved out of the
        // original group, and Darwin rejects a mixed-UID group signal entirely.
        _ = Darwin.kill(processGroup, signal)
    }

    private static func terminationStatus(from rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        if signal == 0 { return (rawStatus >> 8) & 0xff }
        return signal
    }

    private static func makeCStringArray(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw ProcessRunnerError.launchFailed("Executable path and arguments cannot contain NUL bytes")
        }

        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let duplicate = string.withCString({ strdup($0) }) else {
                freeCStringArray(result)
                throw ProcessRunnerError.launchFailed(errorMessage(for: ENOMEM))
            }
            result.append(duplicate)
        }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for case let pointer? in strings { free(pointer) }
    }

    private static func checkSpawnSetup(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            throw ProcessRunnerError.launchFailed("Could not \(operation): \(errorMessage(for: status))")
        }
    }

    private static func errorMessage(for code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
    }
}
