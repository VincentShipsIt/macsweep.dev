import Darwin
import Foundation

struct DevProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let seconds: UInt64
    let microseconds: UInt64
    let executable: String
}

struct DevProcessJob: Identifiable, Sendable {
    var id: DevProcessIdentity { identity }
    let identity: DevProcessIdentity
    let parentPID: pid_t
    let directory: URL
    let arguments: [String]
    let openFiles: [URL]
    let sharedDependencies: [URL]
    let inspectionIssue: String?

    var name: String { URL(fileURLWithPath: identity.executable).lastPathComponent }
    var label: String { "\(name) (PID \(identity.pid))" }
    var isSystemAgent: Bool {
        identity.executable.hasPrefix("/System/") || identity.executable.hasPrefix("/usr/libexec/")
    }
    var isShell: Bool { ["zsh", "bash", "sh", "fish", "dash"].contains(name) }

    var isStoppableDeveloperJob: Bool {
        guard !isSystemAgent, identity.pid > 1, identity.pid != getpid(), inspectionIssue == nil, !arguments.isEmpty
        else { return false }
        if ["swift-frontend", "swiftc", "clang", "clang++", "rustc", "esbuild", "tsc"].contains(name) { return true }
        let verbs = Set(["build", "test", "dev", "check", "typecheck"])
        let args = Array(arguments.dropFirst())
        if ["cargo", "swift"].contains(name) { return args.first.map(verbs.contains) == true }
        if ["npm", "pnpm", "yarn", "bun"].contains(name) {
            let command = args.first == "run" ? args.dropFirst().first : args.first
            return command.map(verbs.contains) == true
        }
        if name == "node", let script = args.first {
            return script.hasSuffix("/typescript/bin/tsc") || script.hasSuffix("/typescript/lib/tsc.js")
                || script.hasSuffix("/next/dist/bin/next") && args.dropFirst().first.map(verbs.contains) == true
                || script.hasSuffix("/vite/bin/vite.js") && (args.count == 1 || args.dropFirst().first == "build")
        }
        return false
    }
}

struct DevProcessSnapshot: Sendable {
    var jobs: [DevProcessJob] = []
    var issues: [String] = []

    func blockers(target: URL, project: URL) -> [DevProcessJob] {
        let target = target.resolvingSymlinksInPath()
        let project = project.resolvingSymlinksInPath()
        var matching = Set<pid_t>()
        for job in jobs {
            let hasChildren = jobs.contains { $0.parentPID == job.identity.pid }
            let projectUse = (!job.isShell || hasChildren) && DevArtifactPaths.contains(project, job.directory)
            let targetUse =
                job.openFiles.contains { DevArtifactPaths.overlaps(target, $0) }
                || DevArtifactPaths.contains(target, URL(fileURLWithPath: job.identity.executable))
                || job.arguments.filter { $0.hasPrefix("/") }.contains {
                    DevArtifactPaths.overlaps(target, URL(fileURLWithPath: $0))
                }
            let globalBuildUse =
                target.lastPathComponent == "DerivedData"
                && ["Xcode", "xcodebuild", "swift-frontend", "swiftc", "clang", "clang++", "SourceKitService"]
                    .contains(job.name)
            let sharedUse = job.sharedDependencies.contains { DevArtifactPaths.overlaps(target, $0) }
            if projectUse || targetUse || sharedUse || globalBuildUse { matching.insert(job.identity.pid) }
        }
        var changed = true
        while changed {
            let old = matching
            for job in jobs where matching.contains(job.parentPID) { matching.insert(job.identity.pid) }
            changed = matching != old
        }
        return jobs.filter { job in
            matching.contains(job.identity.pid) && (!job.isShell || jobs.contains { $0.parentPID == job.identity.pid })
        }
    }

    func canStop(_ job: DevProcessJob) -> Bool {
        guard job.isStoppableDeveloperJob else { return false }
        var descendants: Set<pid_t> = [job.identity.pid]
        var changed = true
        while changed {
            let old = descendants
            for child in jobs where descendants.contains(child.parentPID) { descendants.insert(child.identity.pid) }
            changed = old != descendants
        }
        return jobs.filter { descendants.contains($0.identity.pid) }.allSatisfy(\.isStoppableDeveloperJob)
    }
}

enum DevArtifactPaths {
    static func contains(_ root: URL, _ child: URL) -> Bool {
        let root = root.standardizedFileURL.path
        let child = child.standardizedFileURL.path
        return child == root || child.hasPrefix(root + "/")
    }

    static func overlaps(_ first: URL, _ second: URL) -> Bool {
        contains(first, second) || contains(second, first)
    }
}

enum DevArtifactIO {
    static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let collector = ScanDiagnostics.current
        let result: T = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    with: Result { try ScanDiagnostics.$current.withValue(collector, operation: operation) })
            }
        }
        try Task.checkCancellation()
        return result
    }
}

enum DevProcessActivity {
    static let processLimit = 4096
    static let descriptorLimit = 200_000

    static func snapshot() async throws -> DevProcessSnapshot {
        try await DevArtifactIO.run { capture() }
    }

    static func identity(for pid: pid_t) -> DevProcessIdentity? {
        var info = proc_bsdinfo()
        guard
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
                == MemoryLayout.size(ofValue: info), info.pbi_uid == getuid()
        else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return DevProcessIdentity(
            pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
            executable: String(cString: path))
    }

    static func capture() -> DevProcessSnapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var result = DevProcessSnapshot()
        let capacity = Int(proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)) / MemoryLayout<pid_t>.size + 64
        guard capacity > 0, capacity <= processLimit else {
            return DevProcessSnapshot(issues: ["Process inventory exceeded its safety limit."])
        }
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard bytes > 0, Int(bytes) < capacity * MemoryLayout<pid_t>.size else {
            return DevProcessSnapshot(issues: ["Process inventory was incomplete."])
        }
        var remainingDescriptors = descriptorLimit
        var dependencyCache: [String: [URL]] = [:]
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 1 && pid != getpid() {
            guard ProcessInfo.processInfo.systemUptime < deadline, remainingDescriptors > 0 else {
                result.issues.append("Process inspection exceeded its time or descriptor limit.")
                break
            }
            do {
                if let job = try inspectProcess(
                    pid, remaining: &remainingDescriptors, deadline: deadline,
                    dependencyCache: &dependencyCache) {
                    result.jobs.append(job)
                    if let issue = job.inspectionIssue, !job.isSystemAgent {
                        result.issues.append("\(job.label): \(issue)")
                    }
                }
            } catch { result.issues.append("PID \(pid): \(error.localizedDescription)") }
        }
        return result
    }

    private static func inspectProcess(
        _ pid: pid_t, remaining: inout Int, deadline: TimeInterval,
        dependencyCache: inout [String: [URL]]
    ) throws -> DevProcessJob? {
        guard let identity = identity(for: pid) else {
            if Darwin.kill(pid, 0) == 0 { throw DevArtifactSafetyError("Process identity is unavailable.") }
            return nil
        }
        var bsd = proc_bsdinfo()
        guard
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd)))
                == MemoryLayout.size(ofValue: bsd)
        else {
            if self.identity(for: pid) != nil { throw DevArtifactSafetyError("Process parent could not be inspected.") }
            return nil
        }
        var vnode = proc_vnodepathinfo()
        guard
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode)))
                == MemoryLayout.size(ofValue: vnode)
        else {
            if self.identity(for: pid) != nil {
                throw DevArtifactSafetyError("Process working directory could not be inspected.")
            }
            return nil
        }
        let cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        let directory = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        let systemAgent =
            identity.executable.hasPrefix("/System/") || identity.executable.hasPrefix("/usr/libexec/")
        let inspectedFiles = openFiles(for: pid, remaining: &remaining, deadline: deadline)
        var issue = inspectedFiles.issue
        let paths = inspectedFiles.paths
        let arguments = systemAgent ? [] : arguments(for: pid)
        var dependencies: [URL] = []
        if !systemAgent {
            do {
                dependencies = try dependencyTargets(directory, cache: &dependencyCache, deadline: deadline)
            } catch { issue = error.localizedDescription }
        }
        guard self.identity(for: pid) == identity else { return nil }
        let job = DevProcessJob(
            identity: identity, parentPID: pid_t(bsd.pbi_ppid), directory: directory,
            arguments: arguments, openFiles: paths, sharedDependencies: dependencies,
            inspectionIssue: issue)
        return job
    }

    private static func dependencyTargets(
        _ directory: URL, cache: inout [String: [URL]],
        deadline: TimeInterval
    ) throws -> [URL] {
        if let cached = cache[directory.path] { return cached }
        let targets = try DevArtifactContent.sharedDependencyTargets(from: directory, deadline: deadline)
        cache[directory.path] = targets
        return targets
    }

    private static func openFiles(for pid: pid_t, remaining: inout Int, deadline: TimeInterval)
        -> (paths: [URL], issue: String?) {
        var issue: String?
        var paths: [URL] = []
        errno = 0
        let requested = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if requested > 0 {
            let capacity = Int(requested) / MemoryLayout<proc_fdinfo>.size + 64
            guard capacity <= remaining else {
                return ([], "Open-file inspection exceeded its descriptor limit.")
            }
            remaining -= capacity
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            errno = 0
            let actual = proc_pidinfo(
                pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * MemoryLayout<proc_fdinfo>.size))
            if actual < 0 || actual == 0 && errno != 0 || Int(actual) >= capacity * MemoryLayout<proc_fdinfo>.size {
                issue = "Open-file inventory changed or was unavailable."
            } else {
                for descriptor in fds.prefix(max(0, Int(actual) / MemoryLayout<proc_fdinfo>.size))
                where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        issue = "Open-file inspection timed out."
                        break
                    }
                    var info = vnode_fdinfowithpath()
                    if proc_pidfdinfo(
                        pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                        Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) {
                        let path = withUnsafePointer(to: &info.pvip.vip_path) {
                            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                        }
                        if path.hasPrefix("/") { paths.append(URL(fileURLWithPath: path).standardizedFileURL) }
                    } else if errno != EBADF && errno != ENOENT && errno != ESRCH {
                        issue = "Some open files could not be inspected."
                    }
                }
            }
        } else if requested < 0 || requested == 0 && errno != 0 {
            issue = "Open files could not be inspected."
        }
        return (paths, issue)
    }

    private static func arguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 1_048_576 else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return [] }
        let count = data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard count > 0, count < 65536 else { return [] }
        var index = 4
        while index < size && data[index] != 0 { index += 1 }
        while index < size && data[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count {
            let start = index
            while index < size && data[index] != 0 { index += 1 }
            guard index < size, let value = String(bytes: data[start..<index], encoding: .utf8) else { return [] }
            result.append(value)
            index += 1
        }
        return result
    }

    static func stop(
        selected: [DevProcessJob],
        snapshot: @Sendable () async throws -> DevProcessSnapshot = { try await DevProcessActivity.snapshot() },
        signal: @Sendable (DevProcessIdentity) throws -> Void = { expected in
            guard DevProcessActivity.identity(for: expected.pid) == expected else {
                throw DevArtifactSafetyError("Process identity changed. Rescan before stopping this job.")
            }
            guard Darwin.kill(expected.pid, SIGTERM) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    ) async -> [String] {
        var errors: [String] = []
        for selectedJob in selected {
            do {
                let current = try await snapshot()
                guard current.issues.isEmpty,
                    let job = current.jobs.first(where: { $0.identity == selectedJob.identity }),
                    job.directory.standardizedFileURL.path == selectedJob.directory.standardizedFileURL.path,
                    job.arguments == selectedJob.arguments, job.parentPID == selectedJob.parentPID,
                    current.canStop(job)
                else {
                    throw DevArtifactSafetyError(
                        "Job changed, has retained descendants, or is not a verified developer job.")
                }
                try Task.checkCancellation()
                try signal(job.identity)
            } catch { errors.append("\(selectedJob.label): \(error.localizedDescription)") }
        }
        return errors
    }
}
