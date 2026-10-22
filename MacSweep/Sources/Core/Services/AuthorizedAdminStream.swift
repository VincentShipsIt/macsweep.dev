import Darwin
import Foundation

/// The root-owned delivery directory has no user-writable entries. Root pins
/// each output inode before granting read access, and waits for the reader's
/// acknowledgement before executing a command. Removing the directory after
/// execution cannot invalidate the reader's already-open descriptors.
enum AuthorizedAdminStream {
    typealias Executor = @Sendable (String, TimeInterval) async throws -> Void

    static func perform(
        trustedScript: String, timeout: TimeInterval,
        onOutput: @escaping ProcessOutputHandler,
        executor: @escaping Executor = { try await PrivilegedRunner.runTrustedAdminScript($0, timeout: $1) }
    ) async throws -> ProcessResult {
        let directory = URL(fileURLWithPath: "/private/var/tmp/macsweep-stream-\(UUID().uuidString)")
        let capture = AdminOutputCapture(directory: directory, onOutput: onOutput)
        let reader = Task {
            while !Task.isCancelled {
                try await capture.poll()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        do {
            try await executor(script(trustedScript, directory: directory), timeout)
            reader.cancel()
            _ = try? await reader.value
            return try await capture.finish()
        } catch {
            reader.cancel()
            _ = try? await reader.value
            await capture.close()
            throw error
        }
    }

    static func script(_ command: String, directory: URL) -> String {
        let quote = PrivilegedRunner.shellQuote
        return """
            umask 077
            delivery=\(quote(directory.path))
            /bin/mkdir -m 711 "$delivery" || exit 125
            trap '/bin/rm -rf "$delivery"' EXIT
            exec 7>"$delivery/stdout" 8>"$delivery/stderr" 9>"$delivery/status"
            /usr/bin/touch "$delivery/ack" || exit 125
            /bin/chmod 600 "$delivery/stdout" "$delivery/stderr" "$delivery/status" "$delivery/ack" || exit 125
            /usr/sbin/chown \(getuid()) "$delivery/stdout" "$delivery/stderr" \\
              "$delivery/status" "$delivery/ack" || exit 125
            ready=0
            while [ ! -s "$delivery/ack" ]; do
              ready=$((ready + 1))
              [ "$ready" -le 100 ] || exit 125
              /bin/sleep 0.05
            done
            # Bound each native output file to at most 4 MiB. Excess output fails the tool,
            # rather than allowing a privileged update to exhaust the volume.
            ulimit -f 4096 || exit 125
            (
            \(command)
            ) >&7 2>&8
            native_status=$?
            /usr/bin/printf '%s' "$native_status" >&9
            exit 0
            """
    }
}

private actor AdminOutputCapture {
    private let directory: URL
    private let onOutput: ProcessOutputHandler
    private var handles: [FileHandle] = []
    private var output = Data()
    private var error = Data()
    private var status = Data()
    private let limit = 4_194_304

    init(directory: URL, onOutput: @escaping ProcessOutputHandler) {
        self.directory = directory
        self.onOutput = onOutput
    }

    func poll() throws {
        if handles.isEmpty {
            var opened: [FileHandle] = []
            do {
                for name in ["stdout", "stderr", "status", "ack"] {
                    let path = directory.appendingPathComponent(name)
                    let descriptor = open(path.path, (name == "ack" ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    opened.append(handle)
                    var info = stat()
                    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                        info.st_uid == getuid(), info.st_nlink == 1
                    else {
                        throw DevArtifactSafetyError("Administrator output identity is unsupported.")
                    }
                }
                try opened[3].write(contentsOf: Data([1]))
                try opened[3].close()
                handles = Array(opened.prefix(3))
            } catch {
                for handle in opened { try? handle.close() }
                return
            }
        }
        try drain()
    }

    private func drain() throws {
        guard handles.count == 3 else { return }
        for index in handles.indices {
            while let data = try handles[index].read(upToCount: 65_536), !data.isEmpty {
                switch index {
                case 0:
                    guard output.count + data.count <= limit else {
                        throw DevArtifactSafetyError("Admin output limit.")
                    }
                    output.append(data)
                    onOutput(.standardOutput, data)
                case 1:
                    guard error.count + data.count <= limit else { throw DevArtifactSafetyError("Admin output limit.") }
                    error.append(data)
                    onOutput(.standardError, data)
                default:
                    guard status.count + data.count <= 32 else { throw DevArtifactSafetyError("Invalid admin status.") }
                    status.append(data)
                }
            }
        }
    }

    func finish() throws -> ProcessResult {
        defer { close() }
        try drain()
        guard let value = String(data: status, encoding: .utf8), let code = Int32(value) else {
            throw DevArtifactSafetyError("Administrator action completed without a verified native result.")
        }
        return ProcessResult(
            status: code, output: String(data: output, encoding: .utf8) ?? "Invalid UTF-8 output",
            error: String(data: error, encoding: .utf8) ?? "Invalid UTF-8 error output",
            outputWasValidUTF8: String(data: output, encoding: .utf8) != nil
                && String(data: error, encoding: .utf8) != nil)
    }

    func close() {
        for handle in handles { try? handle.close() }
        handles = []
    }
}
