import Darwin
import Foundation

enum ToolchainReferenceScanner {
    private struct State {
        var result = ToolchainReferences()
        var seen = Set<String>()
        var count = 0
        let policy: ToolchainPolicy
        let deadline: TimeInterval
        let excluded: [URL]
        var dependenciesOnly = false

        mutating func inspect(_ path: URL, entries: FileManager.DirectoryEnumerator) throws {
            if excluded.contains(where: { DevArtifactPaths.contains($0, path) })
                || [".git", "Library", ".Trash", ".cache"].contains(path.lastPathComponent) {
                entries.skipDescendants()
                return
            }
            guard seen.insert(path.path).inserted else {
                entries.skipDescendants()
                return
            }
            var info = stat()
            guard lstat(path.path, &info) == 0 else {
                result.issues.append("Repository-reference metadata changed or could not be inspected.")
                return
            }
            if info.st_mode & S_IFMT == S_IFDIR || isReference(path) {
                result.witnesses.append(.init(path: path.path, node: .init(path: path.path, status: info)))
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                result.links.append((path, path.resolvingSymlinksInPath()))
                entries.skipDescendants()
                if isReference(path) { result.issues.append("A symbolic-link version file requires manual review.") }
                return
            }
            guard isReference(path), !dependenciesOnly || path.lastPathComponent == "pyvenv.cfg" else { return }
            guard let text = try ToolchainEvidence.read(path) else { return }
            if path.lastPathComponent == "pyvenv.cfg" {
                inspectVenv(text, path: path)
                return
            }
            let parsed = ToolchainReferenceParser.parse(text, filename: path.lastPathComponent, source: path.path)
            result.values += parsed.values
            result.unknownManagers.formUnion(parsed.unknownManagers)
        }

        func isReference(_ path: URL) -> Bool {
            let name = path.lastPathComponent
            return ToolchainReferenceParser.names.contains(name) || name == "pyvenv.cfg"
                || (name.hasPrefix("mise.") || name.hasPrefix(".mise.")) && name.hasSuffix(".toml")
        }

        mutating func inspectVenv(_ text: String, path: URL) {
            for line in text.components(separatedBy: .newlines) where line.hasPrefix("home") {
                let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == 2, fields[0] == "home", fields[1].hasPrefix("/") else {
                    result.unknownManagers.formUnion([.pyenv, .asdf, .mise])
                    continue
                }
                result.links.append((path, URL(fileURLWithPath: fields[1])))
            }
        }

        mutating func scan(_ root: URL) throws {
            result.witnesses.append(try ToolchainEvidence.witness(root))
            var enumerationFailed = false
            guard
                let entries = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil,
                    errorHandler: { _, _ in
                        enumerationFailed = true
                        return false
                    })
            else {
                result.issues.append("A repository-reference root could not be inspected.")
                return
            }
            for case let path as URL in entries {
                try Task.checkCancellation()
                count += 1
                guard count <= policy.maximumReferenceEntries, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw DevArtifactSafetyError("Repository-reference coverage exceeded its inspection limit.")
                }
                try inspect(path, entries: entries)
            }
            if enumerationFailed {
                result.issues.append("Repository-reference coverage is incomplete. All pruning is locked.")
            }
        }
    }

    static func scan(roots: [URL], excluded: [URL], dependencyRoots: [URL] = [], policy: ToolchainPolicy) throws
        -> ToolchainReferences {
        var state = State(
            policy: policy, deadline: ProcessInfo.processInfo.systemUptime + policy.referenceTimeLimit,
            excluded: excluded)
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            do { try state.scan(root) } catch is CancellationError { throw CancellationError() } catch {
                state.result.issues.append(error.localizedDescription)
                break
            }
        }
        var dependencies = State(policy: policy, deadline: state.deadline, excluded: [], dependenciesOnly: true)
        for root in dependencyRoots where FileManager.default.fileExists(atPath: root.path) {
            do { try dependencies.scan(root) } catch is CancellationError { throw CancellationError() } catch {
                dependencies.result.issues.append(error.localizedDescription)
                break
            }
        }
        state.result.witnesses += dependencies.result.witnesses
        state.result.links += dependencies.result.links
        state.result.issues += dependencies.result.issues
        state.result.unknownManagers.formUnion(dependencies.result.unknownManagers)
        return state.result
    }
}
