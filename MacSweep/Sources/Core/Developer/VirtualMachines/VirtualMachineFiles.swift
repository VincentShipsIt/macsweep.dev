import Darwin
import Foundation

struct VirtualMachineFiles {
    let home: URL
    let applications: [URL]

    func scan() -> VirtualMachineInventory {
        var inventory = VirtualMachineInventory()
        append(.orbStack, root: ".orbstack/data", name: "Shared OrbStack VM storage", to: &inventory)
        append(.colima, root: ".colima/_lima/_disks", name: "Colima persistent data disks", to: &inventory)
        appendChildren(.lima, root: ".lima", extensions: [], marker: "lima.yaml", to: &inventory)
        appendChildren(
            .utm, root: "Library/Containers/com.utmapp.UTM/Data/Documents",
            extensions: ["utm"], marker: "config.plist", to: &inventory)
        appendChildren(
            .utm, root: "Library/Containers/com.utmapp.UTM.UTM/Data/Documents",
            extensions: ["utm"], marker: "config.plist", to: &inventory)
        appendChildren(.utm, root: "Documents/UTM", extensions: ["utm"], marker: "config.plist", to: &inventory)
        for root in ["Parallels", "Documents/Parallels"] {
            appendChildren(.parallels, root: root, extensions: ["pvm"], marker: "config.pvs", to: &inventory)
        }
        appendChildren(.virtualBox, root: "VirtualBox VMs", extensions: [], marker: nil, to: &inventory)
        appendChildren(.vagrant, root: ".vagrant.d/boxes", extensions: [], marker: nil, to: &inventory)
        append(
            .docker, root: "Library/Containers/com.docker.docker/Data/vms",
            name: "Persistent Docker Desktop VM disks", to: &inventory)
        if installedBundle(id: "com.anthropic.claudefordesktop") {
            for entry in ["vm_bundles", "claude-code-vm", "local-agent-mode-sessions"] {
                append(
                    .claude, root: "Library/Application Support/Claude/\(entry)",
                    name: "Claude \(entry)", to: &inventory)
            }
        }
        return inventory
    }

    private func installedBundle(id: String) -> Bool {
        for root in applications {
            guard let apps = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            else { continue }
            for app in apps where app.pathExtension == "app" {
                let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
                if info?["CFBundleIdentifier"] as? String == id { return true }
            }
        }
        return false
    }

    private func append(
        _ manager: VirtualMachineManager, root: String, name: String,
        to inventory: inout VirtualMachineInventory
    ) {
        let path = home.appendingPathComponent(root)
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        inventory.installedManagers.insert(manager)
        inventory.targets.append(target(manager, path: path, name: name))
    }

    private func appendChildren(
        _ manager: VirtualMachineManager, root: String, extensions: Set<String>,
        marker: String?, to inventory: inout VirtualMachineInventory
    ) {
        let directory = home.appendingPathComponent(root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        inventory.installedManagers.insert(manager)
        do {
            guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
                throw VirtualMachineError("Linked VM storage retained.")
            }
            let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard entries.count <= 4096 else { throw VirtualMachineError("VM inventory exceeded its entry limit.") }
            for path in entries where !path.lastPathComponent.hasPrefix(".") && !path.lastPathComponent.hasPrefix("_") {
                if !extensions.isEmpty && !extensions.contains(path.pathExtension.lowercased()) { continue }
                if let marker, !FileManager.default.fileExists(atPath: path.appendingPathComponent(marker).path) {
                    continue
                }
                if manager == .virtualBox, !containsVirtualBoxConfig(path) { continue }
                inventory.targets.append(target(manager, path: path, name: path.lastPathComponent))
            }
        } catch { inventory.issues.append("\(manager.title): \(error.localizedDescription)") }
    }

    private func containsVirtualBoxConfig(_ path: URL) -> Bool {
        let children = try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
        return children?.contains { $0.pathExtension == "vbox" } == true
    }

    private func target(_ manager: VirtualMachineManager, path: URL, name: String) -> VirtualMachineTarget {
        let measured = try? Self.measure([path])
        let modified = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return VirtualMachineTarget(
            id: "\(manager.rawValue):\(path.path)", manager: manager, name: name,
            paths: [path], status: "Unknown", measuredBytes: measured?.bytes,
            virtualCapacity: nil, modified: modified, lastUsed: nil,
            retentionReason: manager.retentionReason, evidence: nil,
            nativeSignature: nil, nativeName: nil, persistentState: true)
    }

    struct Measurement {
        let bytes: Int64
        let identities: [DevArtifactIdentity]
        let nodes: [DevArtifactNode]
    }

    static func measure(_ paths: [URL], safety: SafetyChecker? = nil) throws -> Measurement {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var nodes: [DevArtifactNode] = []
        var identities: [DevArtifactIdentity] = []
        var seen: Set<String> = []
        var total: Int64 = 0
        for path in paths {
            let identity = try DevArtifactIdentity.read(path)
            guard path.standardizedFileURL.path == path.resolvingSymlinksInPath().path else {
                throw VirtualMachineError("Linked VM roots are retained.")
            }
            identities.append(identity)
            var pending = [path]
            while let url = pending.popLast() {
                try Task.checkCancellation()
                guard nodes.count < 100_000, ProcessInfo.processInfo.systemUptime < deadline else {
                    throw VirtualMachineError("VM size/identity inspection is incomplete; retained.")
                }
                let status = try inspect(url, safety: safety)
                nodes.append(DevArtifactNode(path: url.path, status: status))
                if seen.insert("\(status.st_dev):\(status.st_ino)").inserted {
                    let (bytes, overflow) = Int64(status.st_blocks).multipliedReportingOverflow(by: 512)
                    let (next, sumOverflow) = total.addingReportingOverflow(bytes)
                    guard bytes >= 0, !overflow, !sumOverflow else { throw VirtualMachineError("VM size overflow.") }
                    total = next
                }
                if status.st_mode & S_IFMT == S_IFDIR {
                    pending += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                }
            }
        }
        try verify(nodes, deadline: deadline)
        try verifyRoots(paths, identities: identities)
        return Measurement(bytes: total, identities: identities, nodes: nodes.sorted { $0.path < $1.path })
    }

    private static func inspect(_ path: URL, safety: SafetyChecker?) throws -> stat {
        var status = stat()
        guard lstat(path.path, &status) == 0, [S_IFREG, S_IFDIR].contains(status.st_mode & S_IFMT) else {
            throw VirtualMachineError("Unreadable, linked or special VM contents are retained.")
        }
        if let safety {
            guard !["pid", "sock"].contains(path.pathExtension.lowercased()) else {
                throw VirtualMachineError(
                    "VM process/socket metadata remains; native teardown cannot be proven inactive.")
            }
            let validation = safety.validateForTrash(path)
            guard validation.isSafe else { throw VirtualMachineError(validation.reason ?? "Protected VM state.") }
            guard status.st_uid == getuid() else { throw VirtualMachineError("VM ownership is unknown.") }
            if path.lastPathComponent == ".git" { throw VirtualMachineError("Source repository contents retained.") }
        }
        return status
    }

    private static func verifyRoots(_ paths: [URL], identities: [DevArtifactIdentity]) throws {
        for (path, identity) in zip(paths, identities) {
            guard path.standardizedFileURL.path == path.resolvingSymlinksInPath().path,
                try DevArtifactIdentity.read(path) == identity
            else {
                throw VirtualMachineError("VM root or parent identity changed during inspection; retained.")
            }
        }
    }

    private static func verify(_ nodes: [DevArtifactNode], deadline: TimeInterval) throws {
        for node in nodes {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VirtualMachineError("VM identity verification exceeded its time limit; retained.")
            }
            var status = stat()
            guard lstat(node.path, &status) == 0, DevArtifactNode(path: node.path, status: status) == node else {
                throw VirtualMachineError("VM files changed during inventory; retained.")
            }
        }
    }
}
