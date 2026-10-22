import CoreFoundation
import Foundation

struct VirtualMachineNative {
    let home: URL
    let command: VirtualMachineCommand
    let executable: @Sendable (VirtualMachineManager) -> String?

    func scan() async -> VirtualMachineInventory {
        var inventory = VirtualMachineInventory()
        for manager in VirtualMachineManager.allCases {
            guard let tool = executable(manager) else { continue }
            inventory.installedManagers.insert(manager)
            inventory.executablePaths[manager] = tool
            do {
                let targets = try await scan(manager, tool: tool, inventory: &inventory)
                guard Set(targets.map(\.id)).count == targets.count else {
                    throw VirtualMachineError("Duplicate VM identities retained.")
                }
                inventory.targets += targets
                inventory.completeManagers.insert(manager)
            } catch { inventory.issues.append("\(manager.title): \(error.localizedDescription)") }
        }
        return inventory
    }

    private func scan(
        _ manager: VirtualMachineManager, tool: String,
        inventory: inout VirtualMachineInventory
    ) async throws -> [VirtualMachineTarget] {
        switch manager {
        case .lima:
            let version = try await read(tool, ["--version"])
            inventory.managerVersions[manager] = version.trimmingCharacters(in: .whitespacesAndNewlines)
            let help = try await read(tool, ["delete", "--help"], help: true)
            guard help.contains("delete INSTANCE"), help.contains("--force"), help.contains("Forcibly kill") else {
                throw VirtualMachineError("Installed Lima deletion interface is unsupported.")
            }
            return try VirtualMachineParsing.objects(
                try await read(
                    tool, ["list", "--json", "--all-fields"],
                    emptyLima: true)
            ).map { try lima($0) }
        case .colima: return try await colima(tool)
        case .orbStack: return try await orbStack(tool)
        case .utm: return try await utm(tool)
        case .parallels: return try await parallels(tool)
        case .virtualBox: return try await virtualBox(tool)
        case .vagrant: return try await vagrant(tool)
        case .docker:
            _ = try await read(tool, ["context", "show"])
            return []
        case .claude: return []
        }
    }

    private func colima(_ tool: String) async throws -> [VirtualMachineTarget] {
        let manager: VirtualMachineManager = .colima
        return try VirtualMachineParsing.objects(try await read(tool, ["list", "--json"])).map { row in
            guard let name = row["name"] as? String, VirtualMachineParsing.validName(name) else {
                throw VirtualMachineError("Unknown Colima profile.")
            }
            let instance = name == "default" ? "colima" : "colima-\(name)"
            let path = home.appendingPathComponent(".colima/_lima/\(instance)")
            return try target(
                manager, id: name, status: row["status"] as? String,
                path: path, capacity: verifiedCapacity(row["disk"]), row: row)
        }
    }

    private func orbStack(_ tool: String) async throws -> [VirtualMachineTarget] {
        let manager: VirtualMachineManager = .orbStack
        let help = try await read(tool, ["list", "--help"], help: true)
        guard help.contains("--format"), help.localizedCaseInsensitiveContains("json") else {
            throw VirtualMachineError(
                "OrbStack has no verified JSON inventory interface; shared storage remains visible.")
        }
        return try VirtualMachineParsing.objects(try await read(tool, ["list", "--format", "json"])).map { row in
            guard let name = row["name"] as? String else { throw VirtualMachineError("Unknown OrbStack machine.") }
            return try target(
                manager, id: name, status: row["state"] as? String ?? row["status"] as? String,
                path: nil, row: row)
        }
    }

    private func utm(_ tool: String) async throws -> [VirtualMachineTarget] {
        let manager: VirtualMachineManager = .utm
        return try VirtualMachineParsing.utm(try await read(tool, ["list"])).map { row in
            try target(
                manager, id: row.id, status: row.status, path: nil,
                row: ["uuid": row.id, "name": row.name, "status": row.status])
        }
    }

    private func parallels(_ tool: String) async throws -> [VirtualMachineTarget] {
        let manager: VirtualMachineManager = .parallels
        return try VirtualMachineParsing.objects(try await read(tool, ["list", "-a", "-i", "--json"])).map { row in
            guard let raw = row["ID"] as? String ?? row["uuid"] as? String,
                let id = UUID(uuidString: raw.trimmingCharacters(in: CharacterSet(charactersIn: "{}")))
            else {
                throw VirtualMachineError("Unknown Parallels identity.")
            }
            let path = (row["Home"] as? String ?? row["home"] as? String).flatMap {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
            }
            return try target(
                manager, id: id.uuidString,
                status: row["State"] as? String ?? row["state"] as? String, path: path, row: row)
        }
    }

    private func vagrant(_ tool: String) async throws -> [VirtualMachineTarget] {
        let manager: VirtualMachineManager = .vagrant
        let rows = try VirtualMachineParsing.vagrant(try await read(tool, ["box", "list", "--machine-readable"]))
        return try rows.map { row in
            guard
                row.name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    VirtualMachineParsing.validComponent(String($0))
                }), VirtualMachineParsing.validComponent(row.version), VirtualMachineParsing.validName(row.provider)
            else {
                throw VirtualMachineError("Invalid Vagrant box path components.")
            }
            let escaped = row.name.replacingOccurrences(of: "/", with: "-VAGRANTSLASH-")
            let path = home.appendingPathComponent(".vagrant.d/boxes/\(escaped)/\(row.version)/\(row.provider)")
            return try target(
                manager, id: "\(row.name):\(row.version):\(row.provider)",
                status: "Reference usage unknown", path: path,
                row: ["name": row.name, "version": row.version, "provider": row.provider])
        }
    }

    private func lima(_ row: [String: Any]) throws -> VirtualMachineTarget {
        guard let name = row["name"] as? String, VirtualMachineParsing.validName(name),
            let directory = row["dir"] as? String, directory.hasPrefix("/")
        else {
            throw VirtualMachineError("Invalid Lima identity or directory.")
        }
        var value = try target(
            .lima, id: name, status: row["status"] as? String,
            path: URL(fileURLWithPath: directory), capacity: verifiedCapacity(row["disk"]), row: row)
        let expected = home.appendingPathComponent(".lima/\(name)").path
        let data = try JSONSerialization.data(withJSONObject: row)
        guard let state = try? JSONDecoder().decode(LimaState.self, from: data) else { return value }
        if value.status == "Stopped", state.isSupported, directory == expected {
            value.retentionReason = nil
        }
        return value
    }

    private struct AdditionalDisk: Decodable {}

    private struct LimaState: Decodable {
        let protected: Bool
        let vmType: String
        let hostAgentPID: Int?
        let driverPID: Int?
        let additionalDisks: [AdditionalDisk]?
        let errors: [String]?
        var isSupported: Bool {
            !protected && vmType == "vz" && (hostAgentPID ?? 0) == 0 && (driverPID ?? 0) == 0
                && (additionalDisks ?? []).isEmpty && (errors ?? []).isEmpty
        }
    }

    private func emptyArray(_ row: [String: Any], _ key: String) -> Bool {
        row[key] == nil || (row[key] as? [Any])?.isEmpty == true
    }
    private func zeroPID(_ row: [String: Any], _ key: String) -> Bool {
        row[key] == nil || row[key] as? Int == 0
    }

    private func virtualBox(_ tool: String) async throws -> [VirtualMachineTarget] {
        let ids = try VirtualMachineParsing.virtualBoxIDs(try await read(tool, ["list", "vms"]))
        var targets: [VirtualMachineTarget] = []
        for id in ids {
            let fields = try VirtualMachineParsing.keyValues(
                try await read(tool, ["showvminfo", id, "--machinereadable"]))
            let path = fields["CfgFile"].flatMap {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0).deletingLastPathComponent() : nil
            }
            targets.append(
                try target(
                    .virtualBox, id: id, status: fields["VMState"],
                    path: path, row: fields))
        }
        return targets
    }

    private func verifiedCapacity(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.int64Value >= 0, number.doubleValue == Double(number.int64Value)
        else { return nil }
        return number.int64Value
    }

    private func target(
        _ manager: VirtualMachineManager, id: String, status: String?, path: URL?,
        capacity: Int64? = nil, row: [String: Any]
    ) throws -> VirtualMachineTarget {
        let name = row["name"] as? String ?? row["Name"] as? String ?? id
        guard !id.isEmpty, id.utf8.count <= 4096, !name.isEmpty else {
            throw VirtualMachineError("Invalid VM identifier.")
        }
        let lastUsed = (row["lastUsedAt"] as? String ?? row["lastUsed"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return VirtualMachineTarget(
            id: "\(manager.rawValue):\(id)", manager: manager, name: name,
            paths: path.map { [$0] } ?? [], status: status ?? "Unknown", measuredBytes: nil,
            virtualCapacity: capacity.flatMap { $0 >= 0 ? $0 : nil }, modified: nil, lastUsed: lastUsed,
            retentionReason: manager.retentionReason, evidence: nil,
            nativeSignature: try VirtualMachineParsing.signature(row), nativeName: id, persistentState: true)
    }

    private func read(
        _ tool: String, _ arguments: [String], help: Bool = false,
        emptyLima: Bool = false
    ) async throws -> String {
        try Task.checkCancellation()
        let result = try await command(tool, arguments, 20)
        try result.checkedSuccess()
        let output = help ? result.output + result.error : result.output
        let diagnosticLines = result.error.split(whereSeparator: \.isNewline)
        let empty =
            emptyLima && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && diagnosticLines.count == 1 && result.error.contains("level=warning")
            && diagnosticLines.first?.hasSuffix(
                "msg=\"No instance found. Run `limactl create` to create an instance.\"") == true
        guard result.outputWasValidUTF8, output.utf8.count <= 8_388_608,
            help || empty || result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw VirtualMachineError("Native VM inventory is incomplete, oversized or reported diagnostics.")
        }
        return output
    }
}
