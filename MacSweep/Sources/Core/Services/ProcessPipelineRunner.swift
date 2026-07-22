import Darwin
import Foundation

// Pipeline lifecycle code intentionally stays in one audit boundary: descriptor
// ownership, process-group creation, timeout cleanup, and deferred reaping must
// evolve together. Splitting these helpers would make that ownership harder to
// verify than the file/type length signals are useful here.
// swiftlint:disable file_length type_body_length

/// Low-level implementation behind `ProcessRunner.runPipeline`.
///
/// The tail stage is spawned first and atomically suspended as the process-group
/// leader. Earlier stages then join that stable group before one `SIGCONT`
/// releases the complete pipeline. This closes the race where a short-lived
/// first command exits before later stages can join its group.
enum ProcessPipelineRunner {
    private static let terminationGrace: TimeInterval = 0.5
    private static let forcedCleanupGrace: TimeInterval = 0.5
    private static let drainPollMilliseconds: Int32 = 20

    private struct PipeDescriptors {
        var read: Int32
        var write: Int32
    }

    private struct LaunchedPipeline {
        let pids: [pid_t]
        let groupLeader: pid_t
    }

    // swiftlint:disable:next function_body_length
    static func run(
        stages: [ProcessPipelineStage],
        timeout: TimeInterval,
        onStageStarted: ProcessPipelineLaunchHandler?
    ) throws -> ProcessResult {
        let lifecycleDeadline = DispatchTime.now() + timeout
        var links = try makeLinks(count: stages.count - 1)
        let createdFinalOutput: PipeDescriptors
        do {
            createdFinalOutput = try makePipe(nonblockingRead: true)
        } catch {
            closeLinks(&links)
            throw error
        }
        var finalOutput = createdFinalOutput
        defer { closeAll(links: &links, finalOutput: &finalOutput) }

        let launched: LaunchedPipeline
        do {
            launched = try launch(
                stages: stages,
                links: links,
                finalOutput: finalOutput,
                onStageStarted: onStageStarted
            )
        } catch let failure as LaunchFailure {
            terminateAndReap(
                processGroup: failure.groupLeader,
                pids: failure.startedPIDs
            )
            throw failure.error
        }

        closeLinks(&links)
        closeDescriptor(finalOutput.write)
        finalOutput.write = -1

        let outputBuffer = LockedBuffer()
        let drainCancellation = CancellationFlag()
        let drains = DispatchGroup()
        let outputRead = finalOutput.read
        finalOutput.read = -1
        startDrain(
            descriptor: outputRead,
            buffer: outputBuffer,
            cancellation: drainCancellation,
            group: drains
        )

        _ = Darwin.kill(-launched.groupLeader, SIGCONT)

        var statuses: [pid_t: Int32] = [:]
        if drains.wait(timeout: lifecycleDeadline) == .success,
           waitForChildren(
               launched,
               statuses: &statuses,
               until: lifecycleDeadline
           ) {
            return try completedResult(
                launched: launched,
                statuses: statuses,
                output: outputBuffer.decodedUTF8
            )
        }

        signalPipeline(launched, statuses: statuses, signal: SIGTERM)
        _ = waitForGroupToDisappear(
            launched.groupLeader,
            until: DispatchTime.now() + terminationGrace
        )
        signalPipeline(launched, statuses: statuses, signal: SIGKILL)

        let cleanupDeadline = DispatchTime.now() + forcedCleanupGrace
        _ = waitForChildren(
            launched,
            statuses: &statuses,
            until: cleanupDeadline
        )
        if drains.wait(timeout: cleanupDeadline) != .success {
            drainCancellation.cancel()
            _ = drains.wait(timeout: DispatchTime.now() + 0.2)
        }
        scheduleDeferredReaping(for: launched.pids, statuses: statuses)

        let output = outputBuffer.decodedUTF8
        throw ProcessRunnerError.timedOut(
            after: timeout,
            partialResult: ProcessResult(
                status: -1,
                output: output.string,
                error: "",
                outputWasValidUTF8: output.wasValid
            )
        )
    }

    private struct LaunchFailure: Error {
        let error: ProcessRunnerError
        let groupLeader: pid_t
        let startedPIDs: [pid_t]
    }

    private static func launch(
        stages: [ProcessPipelineStage],
        links: [PipeDescriptors],
        finalOutput: PipeDescriptors,
        onStageStarted: ProcessPipelineLaunchHandler?
    ) throws -> LaunchedPipeline {
        let descriptors = links.flatMap { [$0.read, $0.write] }
            + [finalOutput.read, finalOutput.write]
        var pids = [pid_t](repeating: 0, count: stages.count)
        var groupLeader: pid_t = 0

        do {
            for index in stages.indices.reversed() {
                let childPID = try spawn(
                    stage: stages[index],
                    index: index,
                    stageCount: stages.count,
                    links: links,
                    finalOutput: finalOutput,
                    descriptors: descriptors,
                    groupLeader: groupLeader
                )
                pids[index] = childPID
                onStageStarted?(index, childPID)
                if groupLeader == 0 { groupLeader = childPID }
            }
        } catch let error as ProcessRunnerError {
            throw LaunchFailure(
                error: error,
                groupLeader: groupLeader,
                startedPIDs: pids.filter { $0 > 1 }
            )
        }
        return LaunchedPipeline(pids: pids, groupLeader: groupLeader)
    }

    // The explicit inputs document descriptor ownership for one spawn operation.
    // swiftlint:disable:next function_body_length function_parameter_count
    private static func spawn(
        stage: ProcessPipelineStage,
        index: Int,
        stageCount: Int,
        links: [PipeDescriptors],
        finalOutput: PipeDescriptors,
        descriptors: [Int32],
        groupLeader: pid_t
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(
            posix_spawn_file_actions_init(&fileActions),
            operation: "initialize pipeline file actions"
        )
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(
            posix_spawnattr_init(&attributes),
            operation: "initialize pipeline attributes"
        )
        defer { posix_spawnattr_destroy(&attributes) }

        try configureInput(
            index: index,
            links: links,
            fileActions: &fileActions
        )
        let outputDescriptor = index == stageCount - 1
            ? finalOutput.write
            : links[index].write
        try check(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                outputDescriptor,
                STDOUT_FILENO
            ),
            operation: "connect pipeline stdout"
        )
        try "/dev/null".withCString { nullPath in
            try check(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDERR_FILENO,
                    nullPath,
                    O_WRONLY,
                    0
                ),
                operation: "discard pipeline stderr"
            )
        }
        for descriptor in descriptors {
            try check(
                posix_spawn_file_actions_addclose(&fileActions, descriptor),
                operation: "close child pipeline descriptor"
            )
        }

        var flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        if groupLeader == 0 { flags |= Int16(POSIX_SPAWN_START_SUSPENDED) }
        try check(
            posix_spawnattr_setflags(&attributes, flags),
            operation: "set pipeline process-group flags"
        )
        try check(
            posix_spawnattr_setpgroup(&attributes, groupLeader),
            operation: "join pipeline process group"
        )

        var argv = try makeCStringArray([stage.executable] + stage.arguments)
        defer { freeCStringArray(argv) }
        var childPID: pid_t = 0
        let spawnStatus = stage.executable.withCString { executablePath in
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
        guard spawnStatus == 0, childPID > 1 else {
            let reason = spawnStatus == 0
                ? "posix_spawn returned an invalid process identifier"
                : errorMessage(for: spawnStatus)
            throw ProcessRunnerError.launchFailed(
                "Pipeline stage \(index + 1) failed: \(reason)"
            )
        }
        return childPID
    }

    private static func configureInput(
        index: Int,
        links: [PipeDescriptors],
        fileActions: inout posix_spawn_file_actions_t?
    ) throws {
        if index > 0 {
            try check(
                posix_spawn_file_actions_adddup2(
                    &fileActions,
                    links[index - 1].read,
                    STDIN_FILENO
                ),
                operation: "connect pipeline stdin"
            )
            return
        }

        let stdinFlags = fcntl(STDIN_FILENO, F_GETFD)
        if stdinFlags >= 0 {
            try check(
                posix_spawn_file_actions_addinherit_np(
                    &fileActions,
                    STDIN_FILENO
                ),
                operation: "inherit pipeline stdin"
            )
        } else if errno != EBADF {
            throw ProcessRunnerError.launchFailed(
                "Could not inspect stdin: \(errorMessage(for: errno))"
            )
        }
    }

    private static func completedResult(
        launched: LaunchedPipeline,
        statuses: [pid_t: Int32],
        output: (string: String, wasValid: Bool)
    ) throws -> ProcessResult {
        for (index, pid) in launched.pids.enumerated() {
            guard let rawStatus = statuses[pid] else { continue }
            let status = terminationStatus(from: rawStatus)
            if status != 0 {
                throw ProcessRunnerError.nonZeroExit(
                    status: status,
                    stderr: "Pipeline stage \(index + 1) exited with status \(status)"
                )
            }
        }
        return ProcessResult(
            status: 0,
            output: output.string,
            error: "",
            outputWasValidUTF8: output.wasValid
        )
    }

    private static func waitForChildren(
        _ launched: LaunchedPipeline,
        statuses: inout [pid_t: Int32],
        until deadline: DispatchTime
    ) -> Bool {
        let leader = launched.groupLeader
        let ordered = launched.pids.filter { $0 != leader } + [leader]
        while statuses.count < launched.pids.count {
            guard DispatchTime.now() < deadline else { return false }
            var madeProgress = false
            for pid in ordered where statuses[pid] == nil {
                if pid == leader,
                   launched.pids.contains(where: { $0 != leader && statuses[$0] == nil }) {
                    continue
                }
                var rawStatus: Int32 = 0
                let waitStatus = Darwin.waitpid(pid, &rawStatus, WNOHANG)
                if waitStatus == pid {
                    statuses[pid] = rawStatus
                    madeProgress = true
                } else if waitStatus == -1 && errno != EINTR {
                    return false
                }
            }
            if !madeProgress { usleep(10_000) }
        }
        return true
    }

    private static func terminateAndReap(processGroup: pid_t, pids: [pid_t]) {
        if processGroup > 1 {
            signalGroup(processGroup, signal: SIGKILL)
        }
        // Directly signal every unreaped stage too. A command can move itself
        // out of the original process group; its PID cannot be reused while it
        // remains our unreaped child, so these targeted kills are race-safe.
        for pid in pids { _ = Darwin.kill(pid, SIGKILL) }
        let launched = LaunchedPipeline(pids: pids, groupLeader: processGroup)
        var statuses: [pid_t: Int32] = [:]
        _ = waitForChildren(
            launched,
            statuses: &statuses,
            until: DispatchTime.now() + forcedCleanupGrace
        )
        scheduleDeferredReaping(for: pids, statuses: statuses)
    }

    private static func scheduleDeferredReaping(
        for pids: [pid_t],
        statuses: [pid_t: Int32]
    ) {
        for pid in pids where pid > 1 && statuses[pid] == nil {
            DeferredReaper.schedule(pid)
        }
    }

    private static func makeLinks(count: Int) throws -> [PipeDescriptors] {
        var links: [PipeDescriptors] = []
        do {
            for _ in 0..<max(0, count) {
                // Intermediate read ends become child stdin and must remain
                // blocking. O_NONBLOCK belongs only on the parent's tail drain.
                links.append(try makePipe(nonblockingRead: false))
            }
            return links
        } catch {
            for link in links {
                closeDescriptor(link.read)
                closeDescriptor(link.write)
            }
            throw error
        }
    }

    private static func makePipe(nonblockingRead: Bool) throws -> PipeDescriptors {
        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeStatus = descriptors.withUnsafeMutableBufferPointer {
            Darwin.pipe($0.baseAddress!)
        }
        guard pipeStatus == 0 else {
            throw ProcessRunnerError.launchFailed(errorMessage(for: errno))
        }
        do {
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
                let flags = fcntl(descriptor, F_GETFD)
                guard flags >= 0,
                      fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
                    throw ProcessRunnerError.launchFailed(errorMessage(for: errno))
                }
            }
            if nonblockingRead {
                let statusFlags = fcntl(descriptors[0], F_GETFL)
                guard statusFlags >= 0,
                      fcntl(descriptors[0], F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
                    throw ProcessRunnerError.launchFailed(errorMessage(for: errno))
                }
            }
        } catch {
            closeDescriptor(descriptors[0])
            closeDescriptor(descriptors[1])
            throw error
        }
        return PipeDescriptors(read: descriptors[0], write: descriptors[1])
    }

    private static func closeLinks(_ links: inout [PipeDescriptors]) {
        for index in links.indices {
            closeDescriptor(links[index].read)
            links[index].read = -1
            closeDescriptor(links[index].write)
            links[index].write = -1
        }
    }

    private static func closeAll(
        links: inout [PipeDescriptors],
        finalOutput: inout PipeDescriptors
    ) {
        closeLinks(&links)
        closeDescriptor(finalOutput.read)
        finalOutput.read = -1
        closeDescriptor(finalOutput.write)
        finalOutput.write = -1
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

    private static func startDrain(
        descriptor: Int32,
        buffer: LockedBuffer,
        cancellation: CancellationFlag,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                closeDescriptor(descriptor)
                group.leave()
            }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while !cancellation.isCancelled {
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress!, $0.count)
                }
                if count > 0 {
                    buffer.append(Data(bytes.prefix(Int(count))))
                    continue
                }
                if count == 0 { return }
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { return }

                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollStatus = Darwin.poll(
                    &pollDescriptor,
                    1,
                    drainPollMilliseconds
                )
                if pollStatus < 0 && errno != EINTR { return }
            }
        }
    }

    private static func waitForGroupToDisappear(
        _ processGroup: pid_t,
        until deadline: DispatchTime
    ) -> Bool {
        while DispatchTime.now() < deadline {
            if Darwin.kill(-processGroup, 0) != 0 && errno != EPERM && errno != EINTR {
                return true
            }
            usleep(10_000)
        }
        return false
    }

    private static func signalGroup(_ processGroup: pid_t, signal: Int32) {
        guard processGroup > 1, processGroup != getpgrp() else { return }
        _ = Darwin.kill(-processGroup, signal)
        _ = Darwin.kill(processGroup, signal)
    }

    private static func signalPipeline(
        _ launched: LaunchedPipeline,
        statuses: [pid_t: Int32],
        signal: Int32
    ) {
        signalGroup(launched.groupLeader, signal: signal)
        for pid in launched.pids where pid > 1 && statuses[pid] == nil {
            _ = Darwin.kill(pid, signal)
        }
    }

    private static func terminationStatus(from rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        return signal == 0 ? (rawStatus >> 8) & 0xff : signal
    }

    private static func makeCStringArray(
        _ strings: [String]
    ) throws -> [UnsafeMutablePointer<CChar>?] {
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw ProcessRunnerError.launchFailed(
                "Executable path and arguments cannot contain NUL bytes"
            )
        }
        var result: [UnsafeMutablePointer<CChar>?] = []
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

    private static func freeCStringArray(
        _ strings: [UnsafeMutablePointer<CChar>?]
    ) {
        for case let pointer? in strings { free(pointer) }
    }

    private static func check(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            throw ProcessRunnerError.launchFailed(
                "Could not \(operation): \(errorMessage(for: status))"
            )
        }
    }

    private static func errorMessage(for code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func closeDescriptor(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
    }

    private final class DeferredReaper: @unchecked Sendable {
        private var source: DispatchSourceProcess?

        static func schedule(_ pid: pid_t) { _ = DeferredReaper(pid: pid) }

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
                let retry = waitStatus == 0 || (waitStatus == -1 && errno == EINTR)
                source?.cancel()
                source = nil
                if retry {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + 0.01
                    ) {
                        DeferredReaper.schedule(pid)
                    }
                }
            }
            processSource.resume()
        }
    }
}

// swiftlint:enable file_length type_body_length
