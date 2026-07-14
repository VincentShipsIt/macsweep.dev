import Foundation

/// User-owned path rules shared by the GUI and CLI through ``SafetyChecker``.
///
/// MacSweep intentionally uses two small, line-oriented files in the user's home
/// directory instead of executable configuration:
///
/// - `~/.macsweepignore` omits matching paths from scans and blocks cleanup.
/// - `~/.macsweepprotect` keeps matching paths visible for review but blocks cleanup.
///
/// Rules use path-prefix matching by default. `*`, `**`, and `?` enable glob
/// matching, and a leading `!` makes an exception to an earlier rule in the same
/// file. The last matching rule wins. Exceptions only cancel user rules; they can
/// never weaken MacSweep's built-in safety protections.
struct UserProtectionRules: Sendable {
    enum Decision: Sendable, Equatable {
        case none
        case ignored(pattern: String)
        case protected(pattern: String)
        case loadFailed(reason: String)
    }

    private struct Rule: Sendable {
        let pattern: String
        let normalizedPattern: String
        let regex: String?
        let isException: Bool

        func matches(_ normalizedPath: String) -> Bool {
            if let regex {
                return normalizedPath.range(of: regex, options: .regularExpression) != nil
            }
            return normalizedPath == normalizedPattern
                || normalizedPath.hasPrefix(normalizedPattern + "/")
        }
    }

    static let ignoreFilename = ".macsweepignore"
    static let protectFilename = ".macsweepprotect"
    static let empty = UserProtectionRules(
        ignoreContents: "",
        protectContents: "",
        homeURL: FileManager.default.homeDirectoryForCurrentUser
    )

    private let ignoreRules: [Rule]
    private let protectRules: [Rule]
    private let loadFailureReason: String?

    init(
        ignoreContents: String,
        protectContents: String,
        homeURL: URL,
        loadFailureReason: String? = nil
    ) {
        self.ignoreRules = Self.parse(ignoreContents, homeURL: homeURL)
        self.protectRules = Self.parse(protectContents, homeURL: homeURL)
        self.loadFailureReason = loadFailureReason
    }

    static func load(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> UserProtectionRules {
        let ignoreURL = homeURL.appending(path: ignoreFilename)
        let protectURL = homeURL.appending(path: protectFilename)
        var failures: [String] = []

        func read(_ url: URL) -> String {
            guard fileManager.fileExists(atPath: url.path) else { return "" }
            do {
                return try String(contentsOf: url, encoding: .utf8)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                return ""
            }
        }

        let ignoreContents = read(ignoreURL)
        let protectContents = read(protectURL)
        return UserProtectionRules(
            ignoreContents: ignoreContents,
            protectContents: protectContents,
            homeURL: homeURL,
            loadFailureReason: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
    }

    func decision(for path: String) -> Decision {
        let normalizedPath = SafetyChecker.caseNormalized(
            URL(fileURLWithPath: path).standardized.path
        )

        if let pattern = blockingPattern(in: ignoreRules, for: normalizedPath) {
            return .ignored(pattern: pattern)
        }
        if let pattern = blockingPattern(in: protectRules, for: normalizedPath) {
            return .protected(pattern: pattern)
        }
        if let loadFailureReason {
            return .loadFailed(reason: loadFailureReason)
        }
        return .none
    }

    private func blockingPattern(in rules: [Rule], for normalizedPath: String) -> String? {
        var blockedBy: String?
        for rule in rules where rule.matches(normalizedPath) {
            blockedBy = rule.isException ? nil : rule.pattern
        }
        return blockedBy
    }

    private static func parse(_ contents: String, homeURL: URL) -> [Rule] {
        contents.components(separatedBy: .newlines).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

            let isException = line.hasPrefix("!")
            if isException {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !line.isEmpty else { return nil }

            let expanded = expand(line, homeURL: homeURL)
            let standardized = URL(fileURLWithPath: expanded).standardized.path
            let normalized = SafetyChecker.caseNormalized(
                standardized.count > 1 && standardized.hasSuffix("/")
                    ? String(standardized.dropLast())
                    : standardized
            )
            let hasGlob = normalized.contains("*") || normalized.contains("?")

            return Rule(
                pattern: line,
                normalizedPattern: normalized,
                regex: hasGlob ? globRegex(normalized) : nil,
                isException: isException
            )
        }
    }

    private static func expand(_ pattern: String, homeURL: URL) -> String {
        if pattern == "~" { return homeURL.path }
        if pattern.hasPrefix("~/") {
            return homeURL.appending(path: String(pattern.dropFirst(2))).path
        }
        if pattern.hasPrefix("/") { return pattern }
        return homeURL.appending(path: pattern).path
    }

    private static func globRegex(_ pattern: String) -> String {
        let characters = Array(pattern)
        var regex = "^"
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "/",
               index + 2 < characters.count,
               characters[index + 1] == "*",
               characters[index + 2] == "*",
               index + 3 == characters.count {
                regex += "(?:/.*)?"
                index += 3
            } else if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        regex += "(?:.*/)?"
                        index += 3
                    } else {
                        regex += ".*"
                        index += 2
                    }
                } else {
                    regex += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                regex += "[^/]"
                index += 1
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }

        return regex + "$"
    }
}

extension SafetyChecker {
    func validateUserRules(
        _ path: String,
        mode: ValidationContext.Mode
    ) -> ValidationResult? {
        switch userRules.decision(for: path) {
        case .none:
            return nil
        case .ignored(let pattern):
            return .protected(reason: "Excluded by ~/\(UserProtectionRules.ignoreFilename) rule: \(pattern)")
        case .protected(let pattern):
            switch mode {
            case .scan:
                return nil
            case .cleanup:
                return .protected(reason: "Protected by ~/\(UserProtectionRules.protectFilename) rule: \(pattern)")
            }
        case .loadFailed(let reason):
            switch mode {
            case .scan:
                return nil
            case .cleanup:
                return .protected(reason: "User protection rules could not be loaded: \(reason)")
            }
        }
    }
}
