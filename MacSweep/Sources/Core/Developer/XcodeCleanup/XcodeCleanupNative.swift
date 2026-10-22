import Foundation

struct XcodeCleanupNative {
    let home: URL
    let safety: SafetyChecker
    let command: XcodeCommand

    func scan() async -> XcodeCleanupInventory {
        var inventory = XcodeCleanupInventory()
        do {
            inventory.selectedDeveloper = try await read("/usr/bin/xcode-select", ["-p"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = try await read("/usr/bin/xcrun", ["--find", "simctl"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try validateTool(tool, selected: inventory.selectedDeveloper)
            let runtimeHelp = try await read("/usr/bin/xcrun", ["simctl", "help", "runtime"], includesHelpError: true)
            let deviceHelp = try await read("/usr/bin/xcrun", ["simctl", "help", "delete"], includesHelpError: true)
            guard runtimeHelp.contains("delete (<identifier>"), runtimeHelp.contains("list"),
                deviceHelp.contains("simctl delete <device>")
            else {
                throw XcodeCleanupError("Installed simctl deletion interface is unsupported.")
            }
            let summary = try object(try await read("/usr/bin/xcrun", ["simctl", "list", "-j"]))
            let images = try object(try await read("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]))
            guard let devices = summary["devices"] as? [String: [[String: Any]]],
                let runtimes = summary["runtimes"] as? [[String: Any]],
                devices.values.reduce(0, { $0 + $1.count }) <= 4096, images.count <= 1024
            else {
                throw XcodeCleanupError("Incomplete or oversized simulator inventory; native actions retained.")
            }
            var allDevicesShutdown = true
            for (runtime, entries) in devices {
                for device in entries {
                    let target = try deviceTarget(device, runtime: runtime, context: tool)
                    if device["state"] as? String != "Shutdown" {
                        allDevicesShutdown = false
                    }
                    inventory.targets.append(target)
                }
            }
            for (key, image) in images {
                guard let fields = image as? [String: Any] else {
                    throw XcodeCleanupError("Unknown runtime record retained.")
                }
                var target = try runtimeTarget(fields, key: key, runtimes: runtimes, devices: devices, context: tool)
                if !allDevicesShutdown {
                    target.retentionReason = "A simulator is booted or its activity state is unknown."
                }
                inventory.targets.append(target)
            }
            inventory.nativeCommandsAvailable = true
        } catch {
            inventory.issues.append("Simulator inventory unavailable: \(error.localizedDescription)")
            for index in inventory.targets.indices {
                inventory.targets[index].retentionReason = "Complete simulator inventory could not be verified."
            }
        }
        return inventory
    }

    private func validateTool(_ tool: String, selected: String?) throws {
        guard tool.hasPrefix("/"), tool.hasSuffix("/simctl"),
            let selected, tool.hasPrefix(selected + "/")
        else {
            throw XcodeCleanupError("Selected developer tools do not match simctl. Check DEVELOPER_DIR.")
        }
    }

    private func deviceTarget(_ fields: [String: Any], runtime: String, context: String) throws -> XcodeCleanupTarget {
        guard let raw = fields["udid"] as? String, let id = UUID(uuidString: raw),
            let name = fields["name"] as? String
        else {
            throw XcodeCleanupError("Simulator has an invalid identity.")
        }
        let path = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices/\(id.uuidString)")
        var reason: String?
        if fields["isAvailable"] as? Bool != false { reason = "Available or unknown simulator is retained." }
        if fields["state"] as? String != "Shutdown" { reason = "Running or unknown simulator is retained." }
        if let dataPath = fields["dataPath"] as? String,
            URL(fileURLWithPath: dataPath).standardizedFileURL.path != path.appendingPathComponent("data").path {
            reason = "Custom simulator data location retained."
        }
        var bytes: Int64?
        var evidence: XcodeCleanupEvidence?
        do {
            let measured = try XcodeCleanupFiles.measure(path, safety: safety)
            bytes = measured.bytes
            evidence = XcodeCleanupEvidence(
                identity: measured.evidence.identity, nodes: measured.evidence.nodes,
                nativeSignature: try signature(fields) + runtime + context)
        } catch { reason = error.localizedDescription }
        return XcodeCleanupTarget(
            id: "simulator:\(id.uuidString)", category: .simulators, name: name,
            path: path, bytes: bytes, lastUsed: nil, mechanism: .simulator(id),
            retentionReason: reason, evidence: evidence)
    }

    private func runtimeTarget(
        _ fields: [String: Any], key: String, runtimes: [[String: Any]],
        devices: [String: [[String: Any]]], context: String
    ) throws -> XcodeCleanupTarget {
        guard let raw = fields["identifier"] as? String, let id = UUID(uuidString: raw), raw == key,
            let pathString = fields["path"] as? String, pathString.hasPrefix("/"),
            let runtime = fields["runtimeIdentifier"] as? String
        else {
            throw XcodeCleanupError("Runtime has an invalid identity or storage path.")
        }
        let knownRoots = [
            "/Library/Developer/CoreSimulator/Images/", "/Library/Developer/CoreSimulator/Volumes/",
            "/System/Library/AssetsV2/com_apple_MobileAsset_"
        ]
        var reason: String?
        if !knownRoots.contains(where: pathString.hasPrefix) { reason = "Unknown runtime storage location retained." }
        let matching = runtimes.filter { $0["identifier"] as? String == runtime }
        if matching.count != 1 || matching.first?["isAvailable"] as? Bool != false {
            reason = "Available or unknown runtime is retained."
        }
        if fields["deletable"] as? Bool != true { reason = "Runtime is not tool-deletable." }
        if !["Ready", "Unusable", "Invalid"].contains(fields["state"] as? String ?? "") {
            reason = "Runtime operation or state is unknown."
        }
        if !(devices[runtime] ?? []).isEmpty { reason = "Runtime still has simulator devices; review those first." }
        let aliases = ["path", "mountPath", "runtimeBundlePath", "parentMountPath"]
        for alias in aliases {
            if let value = fields[alias] as? String,
                let check = safety.validateUserRules(value, mode: .cleanup), !check.isSafe {
                reason = check.reason
            }
        }
        let number = fields["sizeBytes"] as? NSNumber
        let bytes = number.flatMap {
            $0.int64Value > 0 && $0.doubleValue == Double($0.int64Value) ? $0.int64Value : nil
        }
        if bytes == nil { reason = "Runtime size is unknown." }
        let date = (fields["lastUsedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        let signature = try signature(fields) + context + matching.map { try signature($0) }.joined()
        return XcodeCleanupTarget(
            id: "runtime:\(id.uuidString)", category: .runtimes,
            name: "\(fields["version"] as? String ?? runtime) (\(fields["build"] as? String ?? "unknown build"))",
            path: URL(fileURLWithPath: pathString), bytes: bytes, lastUsed: date,
            mechanism: .runtime(id), retentionReason: reason,
            evidence: XcodeCleanupEvidence(identity: nil, nodes: [], nativeSignature: signature))
    }

    private func signature(_ fields: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).base64EncodedString()
    }

    private func object(_ string: String) throws -> [String: Any] {
        guard let data = string.data(using: .utf8), data.count <= 16_777_216,
            let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw XcodeCleanupError("Unrecognized or oversized native inventory.")
        }
        return value
    }

    private func read(
        _ executable: String, _ arguments: [String], includesHelpError: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        let result = try await command(executable, arguments, 20)
        try result.checkedSuccess()
        let output = includesHelpError ? result.output + result.error : result.output
        guard result.outputWasValidUTF8, output.utf8.count <= 16_777_216 else {
            throw XcodeCleanupError("Native output is incomplete or oversized.")
        }
        return output
    }
}
