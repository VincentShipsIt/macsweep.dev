import Foundation

/// Parses data files only. Project configuration and shell startup files are never executed.
enum ToolchainReferenceParser {
    static let names: Set<String> = [
        ".nvmrc", ".node-version", ".python-version", ".ruby-version", ".tool-versions",
        "rust-toolchain", "rust-toolchain.toml", "mise.toml", ".mise.toml", "config.toml"
    ]

    static func parse(_ text: String, filename: String, source: String) -> ToolchainReferences {
        var result = ToolchainReferences()
        let lines = text.components(separatedBy: .newlines).map {
            $0.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.filter { !$0.isEmpty }
        switch filename {
        case ".nvmrc", ".node-version", ".python-version", ".ruby-version":
            parseLegacy(lines, filename: filename, source: source, result: &result)
        case ".tool-versions":
            parseToolVersions(lines, source: source, result: &result)
        case "rust-toolchain":
            if lines.count == 1 {
                append(.rustup, "rust", lines[0], source: source, result: &result)
            } else {
                result.unknownManagers.insert(.rustup)
            }
        case "rust-toolchain.toml":
            var found = false
            for line in lines where line.hasPrefix("channel") {
                if let value = quotedAssignment(line) {
                    append(.rustup, "rust", value, source: source, result: &result)
                    found = true
                }
            }
            if !found { result.unknownManagers.insert(.rustup) }
        default:
            parseMise(lines, source: source, result: &result)
        }
        if lines.isEmpty { result.unknownManagers.formUnion(managers(for: filename)) }
        return result
    }

    private static func append(
        _ manager: ToolchainManager, _ tool: String, _ value: String,
        source: String, result: inout ToolchainReferences
    ) {
        for version in value.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(version)
            guard validReference(token) else {
                result.unknownManagers.insert(manager)
                continue
            }
            result.values.append(.init(manager: manager, tool: tool, version: token, source: source))
        }
    }

    private static func parseLegacy(
        _ lines: [String], filename: String, source: String,
        result: inout ToolchainReferences
    ) {
        let tool = filename == ".python-version" ? "python" : (filename == ".ruby-version" ? "ruby" : "node")
        let manager: ToolchainManager = tool == "python" ? .pyenv : (tool == "ruby" ? .rbenv : .nvm)
        for line in lines {
            let version = tool == "ruby" && line.hasPrefix("ruby-") ? String(line.dropFirst(5)) : line
            append(manager, tool, version, source: source, result: &result)
            append(.asdf, tool == "node" ? "nodejs" : tool, version, source: source, result: &result)
            append(.mise, tool, version, source: source, result: &result)
        }
    }

    private static func parseToolVersions(_ lines: [String], source: String, result: inout ToolchainReferences) {
        for line in lines {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let tool = fields.first, fields.count > 1, validIdentifier(tool) else {
                result.unknownManagers.formUnion([.asdf, .mise])
                continue
            }
            let value = fields.dropFirst().joined(separator: " ")
            append(.asdf, tool, value, source: source, result: &result)
            append(.mise, tool == "nodejs" ? "node" : tool, value, source: source, result: &result)
        }
    }

    private static func parseMise(_ lines: [String], source: String, result: inout ToolchainReferences) {
        var inTools = false
        for line in lines {
            if line.hasPrefix("[") {
                inTools = line == "[tools]"
                if line.hasPrefix("[tools.") { result.unknownManagers.insert(.mise) }
                continue
            }
            guard inTools else { continue }
            let fields = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2, validIdentifier(fields[0]), let value = quotedAssignment(line),
                validReference(value)
            else {
                result.unknownManagers.insert(.mise)
                continue
            }
            result.values.append(.init(manager: .mise, tool: fields[0], version: value, source: source))
        }
        // Imports, templates, aliases and dynamic configuration cannot prove absence of references.
        if lines.contains(where: {
            $0.contains("{{") || $0.hasPrefix("[alias") || $0.hasPrefix("[settings")
                || $0.hasPrefix("[env") || $0.hasPrefix("[hooks") || $0.hasPrefix("include")
                || $0.hasPrefix("tools.") || $0.hasPrefix("extends")
        }) {
            result.unknownManagers.insert(.mise)
        }
    }

    static func quotedAssignment(_ line: String) -> String? {
        guard let equal = line.firstIndex(of: "=") else { return nil }
        let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let quote = value.first, ["\"", "'"].contains(quote), value.last == quote else {
            return nil
        }
        let unquoted = String(value.dropFirst().dropLast())
        guard !unquoted.contains("\\"), !unquoted.contains(quote) else { return nil }
        return unquoted
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.first?.isLetter == true
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-")).contains($0)
            }
    }

    static func validVersion(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$", options: .regularExpression) != nil
    }

    static func validReference(_ value: String) -> Bool {
        value == "*" || value == "lts/*"
            || value.range(of: "^[A-Za-z0-9][A-Za-z0-9._+*/-]{0,127}$", options: .regularExpression) != nil
    }

    static func managers(for filename: String) -> Set<ToolchainManager> {
        switch filename {
        case ".nvmrc", ".node-version": return [.nvm, .asdf, .mise]
        case ".python-version": return [.pyenv, .asdf, .mise]
        case ".ruby-version": return [.rbenv, .asdf, .mise]
        case "rust-toolchain", "rust-toolchain.toml": return [.rustup, .mise, .asdf]
        case ".tool-versions": return [.asdf, .mise]
        default: return [.mise]
        }
    }
}
