import Darwin
import Foundation

enum DevArtifactContent {
    static let entryLimit = 100_000
    static let projectIndicators = Array(
        Set(
            DevArtifactPattern.allPatterns
                .filter { $0.projectType != nil }.flatMap(\.siblingIndicators) + [".git"]))
    private static let dependencyNames = ["node_modules", ".venv", "venv", "vendor", ".build", "target"]

    static func projectRoot(
        from directory: URL,
        deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 1
    ) throws -> URL? {
        var current = directory
        var count = 0
        for _ in 0..<8 {
            var failure: Error?
            guard
                let entries = FileManager.default.enumerator(
                    at: current, includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants],
                    errorHandler: { _, error in
                        failure = error
                        return false
                    })
            else {
                throw DevArtifactSafetyError("Project ownership could not be inspected.")
            }
            for case let entry as URL in entries {
                count += 1
                guard count <= 4096, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw DevArtifactSafetyError("Project ownership inspection exceeded its safety limit.")
                }
                if projectIndicators.contains(where: {
                    DevArtifactPattern.indicator($0, matchesFilename: entry.lastPathComponent)
                }) {
                    return current
                }
            }
            if let failure { throw failure }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    static func sharedDependencyTargets(
        from directory: URL, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 1
    ) throws -> [URL] {
        guard let project = try projectRoot(from: directory, deadline: deadline) else { return [] }
        var targets: [URL] = []
        var count = 0
        for name in dependencyNames {
            let root = project.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if rootValues.isSymbolicLink == true {
                targets.append(root.resolvingSymlinksInPath())
                continue
            }
            guard rootValues.isDirectory == true else { continue }
            try inspectDependencyLinks(root, scoped: true, targets: &targets, count: &count, deadline: deadline)
        }
        return targets
    }

    private static func inspectDependencyLinks(
        _ root: URL, scoped: Bool, targets: inout [URL],
        count: inout Int, deadline: TimeInterval
    ) throws {
        var failure: Error?
        guard
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else {
            throw DevArtifactSafetyError("Dependency links could not be inspected.")
        }
        for case let entry as URL in entries {
            count += 1
            guard count <= 4096, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Dependency-link inspection exceeded its limit.")
            }
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                targets.append(entry.resolvingSymlinksInPath())
            } else if scoped && entry.lastPathComponent.hasPrefix("@") {
                try inspectDependencyLinks(entry, scoped: false, targets: &targets, count: &count, deadline: deadline)
            }
        }
        if let failure { throw failure }
    }

    static func validateTree(_ target: URL, genericOutput: Bool, checker: SafetyChecker) throws -> [DevArtifactNode] {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var count = 0
        var content: [DevArtifactNode] = []
        func inspect(_ url: URL) throws {
            count += 1
            guard count <= entryLimit, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Artifact content inspection exceeded its safety limit.")
            }
            content.append(try inspectNode(url, genericOutput: genericOutput, checker: checker))
        }
        try inspect(target)
        var error: Error?
        guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
            return content
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: target, includingPropertiesForKeys: nil,
                errorHandler: { _, issue in
                    error = issue
                    return false
                })
        else {
            throw DevArtifactSafetyError("Artifact contents could not be enumerated.")
        }
        for case let child as URL in enumerator { try inspect(child) }
        if let error { throw error }
        return content.sorted { $0.path < $1.path }
    }

    private static func inspectNode(_ url: URL, genericOutput: Bool, checker: SafetyChecker) throws -> DevArtifactNode {
        var inspected = stat()
        guard Darwin.lstat(url.path, &inspected) == 0 else {
            throw DevArtifactSafetyError("Artifact changed during inspection.")
        }
        let validation = checker.validateForCleanup(
            url, moduleID: "dev-tools",
            itemType: inspected.st_mode & S_IFMT == S_IFREG ? .file : .directory)
        guard validation.isSafe else {
            throw DevArtifactSafetyError(
                "Protected content retained: \(url.lastPathComponent). \(validation.reason ?? "")")
        }
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            throw DevArtifactSafetyError("Artifact content could not be inspected.")
        }
        let type = status.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG || type == S_IFLNK else {
            throw DevArtifactSafetyError("Special filesystem content is retained.")
        }
        let name = url.lastPathComponent.lowercased()
        if name == ".git" { throw DevArtifactSafetyError("Nested Git metadata is retained.") }
        if genericOutput { try validateCompiledOutput(url, type: type) }
        return DevArtifactNode(path: url.path, status: status)
    }

    private static func validateCompiledOutput(_ url: URL, type: mode_t) throws {
        let name = url.lastPathComponent.lowercased()
        let reserved = ["src", "source", "sources", "fixtures", "test", "tests", ".git"]
        if reserved.contains(name) || name == "package.json" || name == "package-lock.json"
            || name == "bun.lock" || name == "bun.lockb" || name == "yarn.lock" || name == "pnpm-lock.yaml"
            || name == "cargo.lock" || name == "cmakelists.txt" || name == "makefile"
            || name.hasPrefix("tsconfig") && name.hasSuffix(".json")
            || name.hasSuffix(".config.js") || name.hasSuffix(".config.ts") || name.hasSuffix(".config.json") {
            throw DevArtifactSafetyError(
                "Source, fixtures, configuration or lockfiles inside this output are retained.")
        }
        let compiledExtensions: Set<String> = [
            "bin", "o", "a", "dylib", "so", "wasm", "class", "pyc", "pyo", "swiftmodule",
            "swiftdoc", "swiftsourceinfo", "pcm", "bc", "air", "metallib"
        ]
        if type != S_IFDIR && !compiledExtensions.contains(url.pathExtension.lowercased()) {
            throw DevArtifactSafetyError(
                "This generic output contains files without compiled-output evidence. Review them in the build tool."
            )
        }
    }

    private static func boundedBuildInfo(_ url: URL) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: 16_777_217), data.count <= 16_777_216 else { return nil }
        return data
    }

    static func isTypeScriptBuildInfo(_ url: URL) throws -> Bool {
        guard url.pathExtension == "tsbuildinfo",
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 16_777_216,
            let data = try boundedBuildInfo(url),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["version"] as? String, !version.isEmpty
        else { return false }
        let program = object["program"] as? [String: Any] ?? object
        return program["fileNames"] is [String] && program["fileInfos"] is [Any]
    }
}
