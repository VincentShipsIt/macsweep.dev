import Foundation

enum UpdateParsers {
    static func brew(_ text: String, source: UpdateSource) throws -> [UpdateVersion] {
        let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: Data(text.utf8))
        if source == .brewFormula {
            return try response.formulae.map {
                var parsed = try version(
                    $0.name, title: $0.name,
                    current: $0.installedVersions.joined(separator: ", "), latest: $0.currentVersion)
                if $0.pinned { parsed.retainedReason = "Pinned in Homebrew. Unpin it manually before updating." }
                return parsed
            }
        }
        return try response.casks.map {
            try version(
                $0.name, title: $0.name, current: $0.installedVersions.joined(separator: ", "),
                latest: $0.currentVersion)
        }
    }

    static func node(_ text: String) throws -> [UpdateVersion] {
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8))
        if let rows = json as? [[String: Any]] {
            return try rows.map { row in
                guard let name = row["name"] as? String else { throw unsupported() }
                return try nodeRow(row, name: name)
            }
        }
        guard let object = json as? [String: Any], object["error"] == nil else { throw unsupported() }
        return try object.keys.sorted().map { name in
            guard let row = object[name] as? [String: Any] else { throw unsupported() }
            return try nodeRow(row, name: name)
        }
    }

    private static func nodeRow(_ row: [String: Any], name: String) throws -> UpdateVersion {
        guard let current = row["current"] as? String, let latest = row["latest"] as? String else {
            throw unsupported()
        }
        return try version(name, title: name, current: current, latest: latest)
    }

    static func mas(_ text: String) throws -> [UpdateVersion] {
        try lines(text).map { line in
            let fields = try captures(#"^\s*([0-9]+)\s+(.+?)\s+\(([^ ]+)\s+->\s+([^\)]+)\)\s*$"#, line)
            return try version(fields[0], title: fields[1], current: fields[2], latest: fields[3])
        }
    }

    static func gem(_ text: String) throws -> [UpdateVersion] {
        try lines(text).map { line in
            let fields = try captures(#"^([A-Za-z0-9_.-]+)\s+\(([^ ]+)\s+<\s+([^\)]+)\)$"#, line)
            return try version(fields[0], title: fields[0], current: fields[1], latest: fields[2])
        }
    }

    struct PipxApp: Sendable {
        let environment: String
        let name: String
        let current: String
        let pinned: Bool
    }

    static func pipxApps(_ text: String) throws -> [PipxApp] {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let environments = object["venvs"] as? [String: Any]
        else { throw unsupported() }
        return try environments.keys.sorted().map { name in
            guard let entry = environments[name] as? [String: Any], let metadata = entry["metadata"] as? [String: Any],
                let main = metadata["main_package"] as? [String: Any], let package = main["package"] as? String,
                let current = main["package_version"] as? String
            else { throw unsupported() }
            return PipxApp(environment: name, name: package, current: current, pinned: main["pinned"] as? Bool ?? false)
        }
    }

    static func pipxOutdated(_ text: String, app: PipxApp) throws -> UpdateVersion? {
        guard let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else {
            throw unsupported()
        }
        let normalized = normalizePython(app.name)
        guard let row = rows.first(where: { ($0["name"] as? String).map(normalizePython) == normalized }) else {
            return nil
        }
        guard let current = row["version"] as? String, let latest = row["latest_version"] as? String else {
            throw unsupported()
        }
        return try version(app.environment, title: app.name, current: current, latest: latest)
    }

    static func validName(_ name: String, source: UpdateSource) -> Bool {
        let pattern: String
        switch source {
        case .mas: return UInt64(name).map { $0 > 0 } ?? false
        case .npm, .pnpm: pattern = #"^(@[a-zA-Z0-9_.-]+/)?[a-zA-Z0-9][a-zA-Z0-9_.-]{0,213}$"#
        case .brewFormula, .brewCask: pattern = #"^[a-zA-Z0-9][a-zA-Z0-9_+.-]*(/[a-zA-Z0-9][a-zA-Z0-9_+.-]*){0,2}$"#
        default: pattern = #"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,213}$"#
        }
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func validVersion(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func version(
        _ name: String, title: String, current: String,
        latest: String
    ) throws -> UpdateVersion {
        guard !name.isEmpty, name.count <= 256, !current.isEmpty, !latest.isEmpty,
            title.count <= 512, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw unsupported() }
        return .init(identifier: name, title: title, current: current, latest: latest)
    }

    private static func captures(_ pattern: String, _ line: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            throw unsupported()
        }
        return try (1..<match.numberOfRanges).map {
            guard let range = Range(match.range(at: $0), in: line) else { throw unsupported() }
            return String(line[range])
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func normalizePython(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression)
    }

    static func unsupported() -> DevArtifactSafetyError {
        .init("Unsupported or incomplete package-manager output. Check this source manually.")
    }
}
