import Foundation

enum VirtualMachineParsing {
    struct UTMRow {
        let id: String
        let name: String
        let status: String
    }
    struct VagrantRow {
        let name: String
        let provider: String
        let version: String
    }

    static func objects(_ output: String) throws -> [[String: Any]] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        guard trimmed.utf8.count <= 8_388_608 else { throw VirtualMachineError("VM output exceeded its size limit.") }
        if trimmed.hasPrefix("[") {
            guard let rows = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [[String: Any]],
                rows.count <= 4096
            else { throw VirtualMachineError("Unsupported VM JSON list.") }
            return rows
        }
        let lines = trimmed.split(whereSeparator: \.isNewline)
        guard lines.count <= 4096 else { throw VirtualMachineError("Too many native VM records.") }
        return try lines.map {
            guard let row = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
                throw VirtualMachineError("Unsupported native VM record.")
            }
            return row
        }
    }

    static func utm(_ output: String) throws -> [UTMRow] {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.first?.split(whereSeparator: \.isWhitespace).prefix(2) == ["UUID", "Status"],
            lines.count <= 4097
        else { throw VirtualMachineError("Unsupported UTM listing.") }
        return try lines.dropFirst().map { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3, let id = UUID(uuidString: fields[0]) else {
                throw VirtualMachineError("Invalid UTM identity.")
            }
            return UTMRow(id: id.uuidString, name: fields[2], status: fields[1] == "stopped" ? "Stopped" : fields[1])
        }
    }

    static func virtualBoxIDs(_ output: String) throws -> [String] {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.count <= 4096 else { throw VirtualMachineError("Too many VirtualBox entries.") }
        return try lines.map { line in
            guard let open = line.lastIndex(of: "{"), line.hasSuffix("}"), line.hasPrefix("\""),
                let id = UUID(uuidString: String(line[line.index(after: open)..<line.index(before: line.endIndex)]))
            else {
                throw VirtualMachineError("Invalid VirtualBox identity.")
            }
            return id.uuidString
        }
    }

    static func keyValues(_ output: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let split = line.firstIndex(of: "=") else { throw VirtualMachineError("Invalid VM properties.") }
            let key = String(line[..<split])
            let raw = String(line[line.index(after: split)...])
            if raw.hasPrefix("\"") {
                result[key] = try JSONDecoder().decode(String.self, from: Data(raw.utf8))
            } else {
                result[key] = raw
            }
        }
        return result
    }

    static func vagrant(_ output: String) throws -> [VagrantRow] {
        var name: String?
        var provider: String?
        var rows: [VagrantRow] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4 else { throw VirtualMachineError("Invalid Vagrant machine-readable output.") }
            let value = fields[3].replacingOccurrences(of: "%!(VAGRANT_COMMA)", with: ",")
            switch fields[2] {
            case "box-name":
                name = value
                provider = nil
            case "box-provider": provider = value
            case "box-version":
                guard let name, let provider else { throw VirtualMachineError("Incomplete Vagrant box identity.") }
                rows.append(VagrantRow(name: name, provider: provider, version: value))
            case "ui", "box-architecture", "box-info": break
            default: throw VirtualMachineError("Unknown Vagrant record type.")
            }
        }
        guard rows.count <= 4096 else { throw VirtualMachineError("Too many Vagrant boxes.") }
        return rows
    }

    static func signature(_ row: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).base64EncodedString()
    }

    static func validComponent(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$"#, options: .regularExpression) != nil
            && !value.contains("..")
    }

    static func validName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil
    }
}
