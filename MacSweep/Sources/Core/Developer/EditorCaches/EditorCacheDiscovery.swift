import Darwin
import Foundation

struct EditorCacheDiscovery {
    let home: URL
    let applications: EditorApplicationInventory
    var issues: [String] = []
    let checker: SafetyChecker
    private let deadline = ProcessInfo.processInfo.systemUptime + 8

    mutating func candidates() -> [EditorCacheCandidate] {
        var result = jetBrains()
        for editor in EditorCacheProduct.editors {
            result += workspaces(editor)
            result += extensions(editor)
        }
        result += electron()
        return result
    }

    private var support: URL { home.appending(path: "Library/Application Support") }

    private mutating func entries(_ root: URL) -> [URL] {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            issues.append("Editor metadata discovery exceeded its budget.")
            return []
        }
        var info = stat()
        if lstat(root.path, &info) != 0 {
            if errno != ENOENT { issues.append("A cache inventory directory is inaccessible.") }
            return []
        }
        do {
            _ = try ManagedCleanupEvidence.identity(root)
            let values = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard values.count <= 10_000 else { throw DevArtifactSafetyError("Cache inventory entry limit exceeded.") }
            return values
        } catch {
            issues.append("Cache inventory incomplete: " + error.localizedDescription)
            return []
        }
    }

    private mutating func jetBrains() -> [EditorCacheCandidate] {
        var result: [EditorCacheCandidate] = []
        for (root, configuration) in [
            (home.appending(path: "Library/Caches/JetBrains"), false),
            (support.appending(path: "JetBrains"), true)
        ] {
            for path in entries(root) {
                let selector = path.lastPathComponent
                let known = EditorCacheMatchers.jetBrainsSelector(selector)
                let current = applications.jetBrainsSelectors.contains(selector)
                let retention =
                    configuration
                    ? "IDE settings and plugins are retained; only cache trees can be cleaned."
                    : !known
                        ? "Unknown product/version directory; retained."
                        : current ? "An installed IDE uses this exact data-directory version; retained." : nil
                result.append(
                    EditorCacheCandidate(
                        path: path, safetyRoot: root, owner: selector,
                        ownerIDs: [], kind: configuration ? .configuration : .jetBrains,
                        evidence: current
                            ? "Installed product-info.json names " + selector
                            : "No installed IDE product-info.json names " + selector,
                        retentionReason: retention))
            }
        }
        return result
    }

    private mutating func workspaces(_ editor: EditorCacheProduct) -> [EditorCacheCandidate] {
        let owner = support.appending(path: editor.directory)
        let root = owner.appending(path: "User/workspaceStorage")
        return entries(root).map { path in
            let match =
                ProcessInfo.processInfo.systemUptime < deadline
                ? try? EditorCacheMatchers.deadWorkspaceReason(
                    path.appending(path: "workspace.json"), home: home, checker: checker)
                : nil
            return EditorCacheCandidate(
                path: path, safetyRoot: owner, owner: editor.name,
                ownerIDs: editor.bundleIDs, kind: .workspace,
                evidence: match?.evidence ?? "Recorded workspace metadata unavailable.",
                retentionReason: match?.retention ?? (match == nil ? "Workspace ownership unknown; retained." : nil))
        }
    }

    private mutating func extensions(_ editor: EditorCacheProduct) -> [EditorCacheCandidate] {
        let root = home.appending(path: editor.extensionDirectory).appending(path: "extensions")
        let paths = entries(root).filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "json" }
        guard !paths.isEmpty else { return [] }
        let registry = try? EditorCacheMatchers.activeExtensions(root)
        var records: [EditorCacheMatchers.ExtensionRecord] = []
        var unknown = Set<String>()
        for path in paths {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                issues.append("Extension metadata discovery exceeded its budget.")
                break
            }
            if let record = try? EditorCacheMatchers.extensionRecord(path) {
                records.append(record)
            } else {
                unknown.insert(path.path)
            }
        }
        let complete = unknown.isEmpty && registry != nil && records.count == paths.count
        let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path.path, $0) })
        let newest = Dictionary(grouping: records, by: \.identifier).mapValues { group in
            group.compactMap(\.version).max { EditorCacheMatchers.older($0, than: $1) }
        }
        return paths.map { path in
            let record = byPath[path.path]
            let latest = record.flatMap { newest[$0.identifier] ?? nil }
            let keep =
                record?.version == nil || latest == nil || record?.version == latest
                || registry?.contains(EditorCacheMatchers.canonical(path).path.lowercased()) == true
            let reason =
                !complete
                ? "Extension manifests or installed registry are incomplete; retained."
                : keep ? "Newest, prerelease, or registered installed extension version retained." : nil
            return EditorCacheCandidate(
                path: path, safetyRoot: root, owner: editor.name, ownerIDs: editor.bundleIDs,
                kind: .obsoleteExtension,
                evidence: record.map {
                    "\($0.identifier) \($0.rawVersion); newest stable and registered versions are retained."
                }
                    ?? "Extension manifest does not match its directory.", retentionReason: reason)
        }
    }

    private mutating func electron() -> [EditorCacheCandidate] {
        var result: [EditorCacheCandidate] = []
        for app in EditorCacheProduct.electron {
            let root = support.appending(path: app.directory)
            for path in entries(root) where ["Cache", "Code Cache", "GPUCache"].contains(path.lastPathComponent) {
                let known = !app.bundleIDs.isDisjoint(with: applications.installedIDs)
                result.append(
                    EditorCacheCandidate(
                        path: path, safetyRoot: root, owner: app.name,
                        ownerIDs: app.bundleIDs, kind: .electron,
                        evidence:
                            "Allowlisted \(app.name) \(path.lastPathComponent); "
                            + "app rebuilds this cache on next launch.",
                        retentionReason: known
                            ? nil : "Owning application is not identified in the installed inventory."))
            }
        }
        return result
    }
}
