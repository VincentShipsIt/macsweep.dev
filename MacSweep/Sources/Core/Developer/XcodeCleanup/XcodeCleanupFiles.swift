import Darwin
import Foundation

struct XcodeCleanupFiles {
    let home: URL
    let applications: [URL]
    let now: Date
    let safety: SafetyChecker
    let systemCaches: URL?

    func scan(selectedDeveloper: String?) -> XcodeCleanupInventory {
        var result = XcodeCleanupInventory()
        let developer = home.appendingPathComponent("Library/Developer")
        for platform in ["iOS", "watchOS", "tvOS"] {
            appendChildren(
                developer.appendingPathComponent("Xcode/\(platform) DeviceSupport"),
                category: .deviceSupport, to: &result)
        }
        let archives = developer.appendingPathComponent("Xcode/Archives")
        for date in children(archives, issues: &result.issues) {
            appendChildren(date, category: .archives, to: &result)
        }
        for path in ["Xcode/UserData/Previews", "CoreSimulator/Caches"] {
            appendChildren(developer.appendingPathComponent(path), category: .previews, to: &result)
        }
        for root in applications {
            for url in children(root, issues: &result.issues)
            where url.lastPathComponent.hasPrefix("Xcode") && url.pathExtension == "app" {
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                guard info?["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode" else { continue }
                var target = inspect(url, category: .applications)
                let selected = selectedDeveloper.map { DevArtifactPaths.contains(url, URL(fileURLWithPath: $0)) }
                if selected != false {
                    target.retentionReason = "Selected Xcode, or selection could not be determined."
                }
                result.targets.append(target)
            }
        }
        appendSystemCaches(to: &result)
        retainNewestArchives(&result.targets)
        return result
    }

    private func appendSystemCaches(to result: inout XcodeCleanupInventory) {
        guard let root = systemCaches else { return }
        var status = stat()
        guard lstat(root.path, &status) == 0 else {
            if errno != ENOENT { result.issues.append("System simulator cache inventory is unreadable.") }
            return
        }
        var size: Int64?
        var reason = "System-owned simulator caches: retained; file-removal authority is unavailable."
        do {
            guard status.st_mode & S_IFMT == S_IFDIR,
                root.standardizedFileURL.path == root.resolvingSymlinksInPath().path
            else {
                throw XcodeCleanupError("Linked or unexpected cache root retained.")
            }
            size = try DevArtifactContent.measure(root).size
        } catch { reason += " Size is incomplete: \(error.localizedDescription)" }
        result.targets.append(
            XcodeCleanupTarget(
                id: root.path, category: .previews, name: "System CoreSimulator Caches", path: root,
                bytes: size, lastUsed: nil, mechanism: .trash, retentionReason: reason, evidence: nil))
    }

    private func appendChildren(
        _ root: URL, category: XcodeCleanupCategory,
        to result: inout XcodeCleanupInventory
    ) {
        for url in children(root, issues: &result.issues) {
            if category == .archives && url.pathExtension != "xcarchive" { continue }
            result.targets.append(inspect(url, category: category))
        }
    }

    private func children(_ root: URL, issues: inout [String]) -> [URL] {
        var status = stat()
        guard lstat(root.path, &status) == 0 else {
            if errno != ENOENT { issues.append("Could not inspect \(root.lastPathComponent).") }
            return []
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
            root.standardizedFileURL.path == root.resolvingSymlinksInPath().path
        else {
            issues.append("Linked or unexpected \(root.lastPathComponent) retained.")
            return []
        }
        do {
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted {
                $0.path < $1.path
            }
        } catch {
            issues.append("Could not list \(root.lastPathComponent).")
            return []
        }
    }

    func inspect(_ url: URL, category: XcodeCleanupCategory) -> XcodeCleanupTarget {
        var evidence: XcodeCleanupEvidence?
        var bytes: Int64?
        var reason: String?
        var date: Date?
        do {
            let measured = try Self.measure(url, safety: safety, appBundle: category == .applications)
            evidence = measured.evidence
            bytes = measured.bytes
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            date = values.contentModificationDate
            if category == .deviceSupport || category == .previews {
                if date.map({ now.timeIntervalSince($0) >= 90 * 86_400 }) != true {
                    reason = "Retained: modified within 90 days, or age is unknown. Modification is not last use."
                }
            }
        } catch { reason = error.localizedDescription }
        return XcodeCleanupTarget(
            id: url.path, category: category, name: url.lastPathComponent,
            path: url, bytes: bytes, lastUsed: date, mechanism: .trash,
            retentionReason: reason, evidence: evidence)
    }

    static func measure(
        _ root: URL, safety: SafetyChecker,
        appBundle: Bool = false
    ) throws -> (bytes: Int64, evidence: XcodeCleanupEvidence) {
        let identity = try DevArtifactIdentity.read(root)
        guard identity.type == S_IFDIR,
            root.standardizedFileURL.path == root.resolvingSymlinksInPath().path
        else {
            throw XcodeCleanupError("Linked or non-directory target retained.")
        }
        let validation = appBundle
            ? safety.validateForAppBundleRemoval(root)
            : safety.validateForTrash(root, developerOwner: .xcode)
        guard validation.isSafe else { throw XcodeCleanupError(validation.reason ?? "Safety validation failed.") }
        let start = Date()
        var stack = [root]
        var nodes: [DevArtifactNode] = []
        var bytes: Int64 = 0
        var seen: Set<String> = []
        while let url = stack.popLast() {
            try Task.checkCancellation()
            guard nodes.count < 500_000, Date().timeIntervalSince(start) < 20 else {
                throw XcodeCleanupError("Size or identity inspection incomplete; target retained.")
            }
            let status = try Self.inspectNode(url, root: root, safety: safety, appBundle: appBundle)
            let type = status.st_mode & S_IFMT
            if seen.insert("\(status.st_dev):\(status.st_ino)").inserted {
                let (allocation, multiplyOverflow) = Int64(status.st_blocks).multipliedReportingOverflow(by: 512)
                let (next, sumOverflow) = bytes.addingReportingOverflow(allocation)
                guard allocation >= 0, !multiplyOverflow, !sumOverflow else {
                    throw XcodeCleanupError("Size overflow; target retained.")
                }
                bytes = next
            }
            nodes.append(DevArtifactNode(path: url.path, status: status))
            if type == S_IFDIR {
                stack += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            }
        }
        try verifyNodes(nodes)
        guard try DevArtifactIdentity.read(root) == identity else {
            throw XcodeCleanupError("Target changed during inspection.")
        }
        return (
            bytes,
            XcodeCleanupEvidence(
                identity: identity, nodes: nodes.sorted { $0.path < $1.path },
                nativeSignature: nil)
        )
    }

    private static func verifyNodes(_ nodes: [DevArtifactNode]) throws {
        for node in nodes {
            try Task.checkCancellation()
            var status = stat()
            guard lstat(node.path, &status) == 0, DevArtifactNode(path: node.path, status: status) == node else {
                throw XcodeCleanupError("Contents changed during measurement; target retained.")
            }
        }
    }

    private static func inspectNode(_ url: URL, root: URL, safety: SafetyChecker, appBundle: Bool) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw XcodeCleanupError("Unreadable contents retained.") }
        let type = status.st_mode & S_IFMT
        if let rule = safety.validateUserRules(url.path, mode: .cleanup), !rule.isSafe {
            throw XcodeCleanupError(rule.reason ?? "Protected contents retained.")
        }
        if appBundle && type == S_IFLNK {
            guard DevArtifactPaths.contains(root, url.resolvingSymlinksInPath()) else {
                throw XcodeCleanupError("Application link escapes its bundle; retained.")
            }
            return status
        }
        guard type == S_IFDIR || type == S_IFREG else {
            throw XcodeCleanupError("Linked or special contents retained.")
        }
        if !appBundle {
            let check = safety.validateForTrash(url, developerOwner: .xcode)
            guard check.isSafe else { throw XcodeCleanupError(check.reason ?? "Protected contents retained.") }
        }
        return status
    }

    private func retainNewestArchives(_ targets: inout [XcodeCleanupTarget]) {
        var groups: [String: [(index: Int, date: Date)]] = [:]
        for index in targets.indices where targets[index].category == .archives {
            let infoURL = targets[index].path.appendingPathComponent("Info.plist")
            guard let info = NSDictionary(contentsOf: infoURL),
                let properties = info["ApplicationProperties"] as? [String: Any],
                let identifier = properties["CFBundleIdentifier"] as? String, !identifier.isEmpty,
                let date = info["CreationDate"] as? Date
            else {
                targets[index].retentionReason = "Archive application or creation date is unknown."
                continue
            }
            groups[identifier, default: []].append((index, date))
        }
        for values in groups.values {
            guard let newest = values.map(\.date).max() else { continue }
            for value in values where value.date == newest {
                targets[value.index].retentionReason = "Newest archive for this application is retained."
            }
        }
    }
}
