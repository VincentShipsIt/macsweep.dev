import Foundation

enum ToolchainGlobalSelections {
    static func collect(location: ToolchainLocation, home: URL, environment: [String: String]) -> ToolchainReferences {
        var result = ToolchainReferences()
        do {
            result.witnesses = try selectionPaths(location, home: home, environment: environment)
                .map(ToolchainEvidence.witness)
            switch location.manager {
            case .pyenv, .rbenv: try legacy(location, environment: environment, result: &result)
            case .asdf: try asdf(home, environment: environment, result: &result)
            case .mise: try mise(home, environment: environment, result: &result)
            case .nvm: try nvm(location, environment: environment, result: &result)
            case .rustup: try rustup(location, environment: environment, result: &result)
            case .java:
                if let value = environment["JAVA_HOME"] {
                    result.links.append((URL(fileURLWithPath: "global-JAVA_HOME"), URL(fileURLWithPath: value)))
                }
            }
        } catch { result.unknownManagers.insert(location.manager) }
        return result
    }

    private static func selectionPaths(
        _ location: ToolchainLocation, home: URL,
        environment: [String: String]
    ) throws -> [URL] {
        let root = location.root
        var paths = [
            root, root.appendingPathComponent("version"), root.appendingPathComponent("settings.toml"),
            home.appendingPathComponent(".tool-versions")
        ]
        if location.manager == .nvm {
            let alias = root.appendingPathComponent("alias")
            paths.append(alias)
            if FileManager.default.fileExists(atPath: alias.path) {
                paths += try FileManager.default.contentsOfDirectory(at: alias, includingPropertiesForKeys: nil)
            }
        }
        if location.manager == .mise {
            let config =
                environment["MISE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".config/mise")
            paths += [config, config.appendingPathComponent("config.toml")]
        }
        return paths
    }

    private static func add(
        _ manager: ToolchainManager, tool: String, value: String, source: String,
        result: inout ToolchainReferences
    ) {
        for token in value.split(whereSeparator: { $0.isWhitespace }) {
            let version = String(token)
            guard ToolchainReferenceParser.validReference(version) else {
                result.unknownManagers.insert(manager)
                continue
            }
            result.values.append(.init(manager: manager, tool: tool, version: version, source: source))
        }
    }

    private static func legacy(
        _ location: ToolchainLocation, environment: [String: String],
        result: inout ToolchainReferences
    ) throws {
        let tool = location.manager == .pyenv ? "python" : "ruby"
        if let value = try ToolchainEvidence.read(location.root.appendingPathComponent("version")) {
            add(location.manager, tool: tool, value: value, source: "global selection", result: &result)
        }
        let variable = location.manager == .pyenv ? "PYENV_VERSION" : "RBENV_VERSION"
        if let value = environment[variable] {
            add(location.manager, tool: tool, value: value, source: variable, result: &result)
        }
    }

    private static func asdf(_ home: URL, environment: [String: String], result: inout ToolchainReferences) throws {
        if let value = try ToolchainEvidence.read(home.appendingPathComponent(".tool-versions")) {
            merge(
                ToolchainReferenceParser.parse(value, filename: ".tool-versions", source: "global selection"),
                into: &result)
        }
        for (name, value) in environment where name.hasPrefix("ASDF_") && name.hasSuffix("_VERSION") {
            let tool = name.dropFirst(5).dropLast(8).lowercased()
            add(.asdf, tool: tool, value: value, source: name, result: &result)
        }
        if environment["ASDF_CONFIG_FILE"] != nil { result.unknownManagers.insert(.asdf) }
    }

    private static func mise(_ home: URL, environment: [String: String], result: inout ToolchainReferences) throws {
        let config =
            environment["MISE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config/mise")
        if let value = try ToolchainEvidence.read(config.appendingPathComponent("config.toml")) {
            merge(
                ToolchainReferenceParser.parse(value, filename: "config.toml", source: "global selection"),
                into: &result)
        }
        if FileManager.default.fileExists(atPath: config.path) {
            let files = try FileManager.default.contentsOfDirectory(at: config, includingPropertiesForKeys: nil)
            if files.contains(where: { $0.lastPathComponent != "config.toml" }) {
                result.unknownManagers.insert(.mise)
            }
        }
        let supported: Set<String> = ["MISE_DATA_DIR", "MISE_CONFIG_DIR"]
        if environment.keys.contains(where: { $0.hasPrefix("MISE_") && !supported.contains($0) }) {
            result.unknownManagers.insert(.mise)
        }
    }

    private static func nvm(
        _ location: ToolchainLocation, environment: [String: String],
        result: inout ToolchainReferences
    ) throws {
        let aliases = location.root.appendingPathComponent("alias")
        if FileManager.default.fileExists(atPath: aliases.path) {
            let entries = try FileManager.default.contentsOfDirectory(at: aliases, includingPropertiesForKeys: nil)
            for entry in entries where entry.lastPathComponent != "lts" {
                guard let value = try ToolchainEvidence.read(entry) else { continue }
                add(.nvm, tool: "node", value: value, source: "nvm alias " + entry.lastPathComponent, result: &result)
            }
        }
        if let bin = environment["NVM_BIN"] {
            let version = URL(fileURLWithPath: bin).deletingLastPathComponent().lastPathComponent
            add(.nvm, tool: "node", value: version, source: "NVM_BIN", result: &result)
        }
    }

    private static func rustup(
        _ location: ToolchainLocation, environment: [String: String],
        result: inout ToolchainReferences
    ) throws {
        guard let settings = try ToolchainEvidence.read(location.root.appendingPathComponent("settings.toml")) else {
            result.unknownManagers.insert(.rustup)
            return
        }
        var overrides = false
        var hasDefault = false
        for raw in settings.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                overrides = line == "[overrides]"
                continue
            }
            guard line.hasPrefix("default_toolchain") || overrides && line.contains("=") else { continue }
            guard let value = ToolchainReferenceParser.quotedAssignment(line) else {
                result.unknownManagers.insert(.rustup)
                continue
            }
            add(
                .rustup, tool: "rust", value: value, source: overrides ? "rustup override" : "global selection",
                result: &result)
            if !overrides { hasDefault = true }
        }
        if !hasDefault { result.unknownManagers.insert(.rustup) }
        if let value = environment["RUSTUP_TOOLCHAIN"] {
            add(.rustup, tool: "rust", value: value, source: "RUSTUP_TOOLCHAIN", result: &result)
        }
    }

    private static func merge(_ other: ToolchainReferences, into result: inout ToolchainReferences) {
        result.values += other.values
        result.unknownManagers.formUnion(other.unknownManagers)
    }
}
