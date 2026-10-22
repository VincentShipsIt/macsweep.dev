import Darwin
import Foundation

enum EditorCacheMatchers {
    static func canonical(_ path: URL) -> URL {
        var ancestor = path
        var tail: [String] = []
        while tail.count < 128 {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                return tail.reversed().reduce(URL(fileURLWithPath: String(cString: resolved))) {
                    $0.appending(path: $1)
                }
            }
            guard errno == ENOENT, ancestor.path != "/" else { break }
            tail.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return path.standardizedFileURL
    }

    static func json(_ path: URL) throws -> [String: Any] {
        let data = try boundedData(path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DevArtifactSafetyError("Metadata format is unknown.")
        }
        return json
    }

    static func boundedData(_ path: URL) throws -> Data {
        _ = try ManagedCleanupEvidence.identity(path)
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DevArtifactSafetyError("Metadata could not be opened safely.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 2_097_152 else {
            throw DevArtifactSafetyError("Metadata is unavailable or exceeds its inspection limit.")
        }
        let data = try handle.read(upToCount: 2_097_152) ?? Data()
        guard data.count < 2_097_152 else { throw DevArtifactSafetyError("Metadata grew beyond its inspection limit.") }
        return data
    }

    static func jetBrainsSelector(_ name: String) -> Bool {
        let pattern =
            "^(IntelliJIdea|IdeaIC|PyCharm|PyCharmCE|WebStorm|PhpStorm|CLion|DataGrip|Rider|GoLand|RubyMine|"
            + "RustRover|Aqua|DataSpell)20[0-9]{2}\\.[0-9]+(\\.[0-9]+)?(EAP)?$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func deadWorkspaceReason(_ metadata: URL, home: URL, checker: SafetyChecker) throws -> (
        evidence: String, retention: String?
    ) {
        let record = try json(metadata)
        let paths = [record["folder"], record["workspace"]].compactMap { $0 as? String }
        guard paths.count == 1, let value = paths.first, let url = URL(string: value), url.isFileURL,
            url.host == nil || url.host == "" || url.host == "localhost",
            url.path.utf8.count < 8192, !url.pathComponents.contains(".."),
            canonical(url).path.hasPrefix(canonical(home).path + "/")
        else {
            return (
                "Workspace metadata is remote, ambiguous or outside the local home.",
                "Workspace ownership is uncertain."
            )
        }
        let cloudRoots = [
            "Library/CloudStorage", "Library/Mobile Documents", "iCloud Drive", "Dropbox", "Google Drive", "OneDrive"
        ]
        if cloudRoots.contains(where: { component in
            let root = canonical(home.appending(path: component)).path
            let path = canonical(url).path
            return path == root || path.hasPrefix(root + "/")
        }) {
            return (
                "Recorded workspace is in cloud-managed storage.", "Offline cloud state cannot prove a dead workspace."
            )
        }
        if let rule = checker.validateUserRules(url.path, mode: .cleanup), !rule.isSafe {
            return ("Recorded workspace matches a protection rule.", "Protected workspace retained.")
        }
        var info = stat()
        let status = lstat(url.path, &info)
        if status == 0 { return ("Recorded workspace exists: " + url.path, "Existing workspace retained.") }
        guard errno == ENOENT else {
            return ("Recorded workspace access is unavailable.", "Permission or filesystem uncertainty; retained.")
        }
        var parent = url.deletingLastPathComponent()
        while canonical(parent).path == canonical(home).path
            || canonical(parent).path.hasPrefix(canonical(home).path + "/") {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path)) != nil {
                return ("Recorded workspace has a symbolic-link ancestor.", "Linked workspace retained.")
            }
            parent.deleteLastPathComponent()
        }
        return ("Recorded local workspace is missing: " + url.path, nil)
    }

    struct ExtensionRecord {
        let path: URL
        let identifier: String
        let version: [Int]?
        let rawVersion: String
    }

    static func extensionRecord(_ path: URL) throws -> ExtensionRecord {
        let metadata = try json(path.appending(path: "package.json"))
        guard let publisher = metadata["publisher"] as? String, let name = metadata["name"] as? String,
            let version = metadata["version"] as? String,
            [publisher, name].allSatisfy({
                $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil
            })
        else {
            throw DevArtifactSafetyError("Extension identity metadata unavailable.")
        }
        let identifier = publisher + "." + name
        let prefix = identifier + "-" + version
        let suffixes = ["", "-darwin-arm64", "-darwin-x64", "-universal", "-linux-x64", "-linux-arm64", "-win32-x64"]
        guard suffixes.contains(where: { path.lastPathComponent.lowercased() == (prefix + $0).lowercased() }) else {
            throw DevArtifactSafetyError("Extension directory does not match its manifest.")
        }
        let stable =
            version.range(of: "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$", options: .regularExpression)
            != nil
        let parts = stable ? version.split(separator: ".").compactMap { Int($0) } : []
        return ExtensionRecord(
            path: path, identifier: identifier.lowercased(), version: parts.count == 3 ? parts : nil,
            rawVersion: version)
    }

    static func activeExtensions(_ root: URL) throws -> Set<String> {
        let data = try boundedData(root.appending(path: "extensions.json"))
        guard let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DevArtifactSafetyError("Installed extension registry unavailable.")
        }
        var paths = Set<String>()
        for record in records {
            guard let identifier = record["identifier"] as? [String: Any], identifier["id"] is String,
                record["version"] is String, let relative = record["relativeLocation"] as? String,
                !relative.isEmpty, !relative.contains("/"), relative != ".", relative != ".."
            else {
                throw DevArtifactSafetyError("Installed extension registry contains an unknown location.")
            }
            paths.insert(canonical(root.appending(path: relative)).path.lowercased())
        }
        return paths
    }

    static func older(_ lhs: [Int], than rhs: [Int]) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }
}
