import Foundation

enum AssistantTOMLError: LocalizedError {
    case invalidLine(String)
    case invalidValue(key: String, value: String)

    var errorDescription: String? {
        switch self {
        case .invalidLine(let line):
            return "Invalid TOML line: \(line)"
        case .invalidValue(let key, let value):
            return "Invalid TOML value for \(key): \(value)"
        }
    }
}

enum AssistantTOMLCodec {
    static func parseProviders(_ content: String) throws -> AssistantProvidersConfiguration {
        var config = AssistantProvidersConfiguration.default
        var currentProvider: AssistantProviderKind?

        for line in logicalLines(from: content) {
            if line.hasPrefix("[") && line.hasSuffix("]") {
                currentProvider = AssistantProviderKind(
                    rawValue: String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                )
                continue
            }

            let (key, value) = try keyValue(from: line)

            if let currentProvider {
                guard var providerConfig = config.providers[currentProvider] else { continue }

                switch key {
                case "enabled":
                    providerConfig.enabled = try parseBool(value, key: key)
                case "command":
                    providerConfig.command = try parseString(value, key: key)
                case "model":
                    providerConfig.model = try parseString(value, key: key)
                case "reasoning_effort":
                    providerConfig.reasoningEffort = try parseString(value, key: key)
                default:
                    break
                }

                config.providers[currentProvider] = providerConfig
            } else {
                switch key {
                case "default_provider":
                    config.defaultProvider = try parseProvider(value)
                case "fallback_order":
                    config.fallbackOrder = try parseStringArray(value, key: key).compactMap(AssistantProviderKind.init(rawValue:))
                default:
                    break
                }
            }
        }

        if !config.fallbackOrder.contains(config.defaultProvider) {
            config.fallbackOrder.insert(config.defaultProvider, at: 0)
        }

        return config
    }

    static func renderProviders(_ config: AssistantProvidersConfiguration) -> String {
        var lines = [
            "# MacSweep assistant provider configuration",
            "# Codex is the default provider and uses GPT-5.4-mini with medium reasoning.",
            "default_provider = \"\(config.defaultProvider.rawValue)\"",
            "fallback_order = \(renderStringArray(config.fallbackOrder.map(\.rawValue)))",
            "",
        ]

        for provider in AssistantProviderKind.allCases {
            guard let entry = config.providers[provider] else { continue }
            lines.append("[\(provider.rawValue)]")
            lines.append("enabled = \(entry.enabled ? "true" : "false")")
            lines.append("command = \"\(entry.command)\"")
            lines.append("model = \"\(entry.model)\"")
            lines.append("reasoning_effort = \"\(entry.reasoningEffort)\"")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) + "\n"
    }

    static func parseWatchlists(_ content: String) throws -> [AssistantWatchlistRule] {
        struct RuleDraft {
            var id: String?
            var label: String?
            var enabled = true
            var source = "user"
            var rationale = ""
            var paths: [String] = []
            var excludePaths: [String] = []
        }

        var rules: [RuleDraft] = []
        var current = RuleDraft()
        var hasRule = false

        func flushCurrent() {
            guard hasRule else { return }
            rules.append(current)
            current = RuleDraft()
            hasRule = false
        }

        for line in logicalLines(from: content) {
            if line == "[[rules]]" {
                flushCurrent()
                hasRule = true
                continue
            }

            let (key, value) = try keyValue(from: line)
            switch key {
            case "version":
                continue
            case "id":
                current.id = try parseString(value, key: key)
            case "label":
                current.label = try parseString(value, key: key)
            case "enabled":
                current.enabled = try parseBool(value, key: key)
            case "source":
                current.source = try parseString(value, key: key)
            case "rationale":
                current.rationale = try parseString(value, key: key)
            case "paths":
                current.paths = try parseStringArray(value, key: key)
            case "exclude_paths":
                current.excludePaths = try parseStringArray(value, key: key)
            default:
                continue
            }
        }

        flushCurrent()

        return rules.enumerated().compactMap { index, draft in
            guard !draft.paths.isEmpty else { return nil }

            let label = draft.label ?? draft.id ?? "Watchlist Rule \(index + 1)"
            let id = draft.id ?? sanitizedID(from: label, fallbackIndex: index)

            return AssistantWatchlistRule(
                id: id,
                label: label,
                enabled: draft.enabled,
                source: draft.source,
                rationale: draft.rationale.isEmpty ? "User-defined watchlist rule." : draft.rationale,
                paths: draft.paths,
                excludePaths: draft.excludePaths
            )
        }
    }

    static func renderWatchlists(_ rules: [AssistantWatchlistRule]) -> String {
        var lines = [
            "# MacSweep persistent watchlists",
            "# Each rule adds scan roots the assistant or user wants MacSweep to monitor.",
            "version = 1",
            "",
        ]

        for rule in rules.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) {
            lines.append("[[rules]]")
            lines.append("id = \"\(rule.id)\"")
            lines.append("label = \"\(escape(rule.label))\"")
            lines.append("enabled = \(rule.enabled ? "true" : "false")")
            lines.append("source = \"\(escape(rule.source))\"")
            lines.append("rationale = \"\(escape(rule.rationale))\"")
            lines.append("paths = \(renderStringArray(rule.paths))")
            lines.append("exclude_paths = \(renderStringArray(rule.excludePaths))")
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) + "\n"
    }

    private static func logicalLines(from content: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var bracketDepth = 0

        for rawLine in content.components(separatedBy: .newlines) {
            let stripped = stripComments(from: rawLine).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty && bracketDepth == 0 {
                continue
            }

            if current.isEmpty {
                current = stripped
            } else if !stripped.isEmpty {
                current += " " + stripped
            }

            bracketDepth += stripped.reduce(into: 0) { partial, character in
                if character == "[" {
                    partial += 1
                } else if character == "]" {
                    partial -= 1
                }
            }

            if bracketDepth <= 0 {
                if !current.isEmpty {
                    lines.append(current)
                }
                current = ""
                bracketDepth = 0
            }
        }

        if !current.isEmpty {
            lines.append(current)
        }

        return lines
    }

    private static func stripComments(from line: String) -> String {
        var result = ""
        var inString = false
        var escaped = false

        for character in line {
            // Inside a string, a backslash escapes the next character, so neither
            // `\"` (escaped quote) nor `\\` (escaped backslash) wrongly ends the
            // string and exposes a following `#` as a comment marker.
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            if inString && character == "\\" {
                result.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                inString.toggle()
            } else if character == "#" && !inString {
                break
            }
            result.append(character)
        }

        return result
    }

    private static func keyValue(from line: String) throws -> (String, String) {
        guard let separator = line.firstIndex(of: "=") else {
            throw AssistantTOMLError.invalidLine(line)
        }

        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func parseProvider(_ rawValue: String) throws -> AssistantProviderKind {
        let providerName = try parseString(rawValue, key: "default_provider")
        guard let provider = AssistantProviderKind(rawValue: providerName) else {
            throw AssistantTOMLError.invalidValue(key: "default_provider", value: rawValue)
        }
        return provider
    }

    private static func parseString(_ rawValue: String, key: String) throws -> String {
        guard rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.count >= 2 else {
            throw AssistantTOMLError.invalidValue(key: key, value: rawValue)
        }

        return unescape(String(rawValue.dropFirst().dropLast()))
    }

    private static func parseBool(_ rawValue: String, key: String) throws -> Bool {
        switch rawValue {
        case "true":
            return true
        case "false":
            return false
        default:
            throw AssistantTOMLError.invalidValue(key: key, value: rawValue)
        }
    }

    private static func parseStringArray(_ rawValue: String, key: String) throws -> [String] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            throw AssistantTOMLError.invalidValue(key: key, value: rawValue)
        }

        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else { return [] }

        var values: [String] = []
        var current = ""
        var inString = false
        var escaped = false

        for character in inner {
            if inString && escaped {
                // Preserve the raw escape sequence so a `\"` doesn't prematurely
                // close the element; `unescape` resolves it once at the boundary.
                current.append("\\")
                current.append(character)
                escaped = false
                continue
            }
            if inString && character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" {
                if inString {
                    values.append(unescape(current))
                }
                current = ""
                inString.toggle()
                continue
            }
            if inString {
                current.append(character)
            }
            // Characters between elements (commas, whitespace) are ignored.
        }

        return values
    }

    private static func renderStringArray(_ values: [String]) -> String {
        "[" + values.map { "\"\(escape($0))\"" }.joined(separator: ", ") + "]"
    }

    private static func sanitizedID(from label: String, fallbackIndex: Int) -> String {
        let base = label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return base.isEmpty ? "watchlist-\(fallbackIndex + 1)" : base
    }

    private static func escape(_ value: String) -> String {
        // Backslash MUST be escaped before quote, otherwise a value already
        // containing `\"` would gain an extra backslash that the un-escape step
        // can't recover. `"\\"` is one backslash; `"\\\\"` is two.
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Reverse of `escape`. Single pass so it can't suffer the ordering hazard of
    /// chained `replacingOccurrences` calls: a backslash consumes the next
    /// character literally, so `\\` → `\` and `\"` → `"` round-trip exactly.
    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }   // trailing lone backslash, kept as-is
        return result
    }
}
