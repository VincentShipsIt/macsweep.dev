import Foundation

enum UserProtectionRuleFileError: LocalizedError {
    case invalidPattern(String)
    case invalidRule(line: Int, reason: String)
    case readFailed(URL, any Error)
    case writeFailed(URL, any Error)
    case unexpectedFile(URL)

    var errorDescription: String? {
        switch self {
        case .invalidPattern(let reason):
            reason
        case .invalidRule(let line, let reason):
            "Rule on line \(line) is invalid: \(reason)"
        case .readFailed(let url, let error):
            "Couldn't read \(url.path): \(error.localizedDescription)"
        case .writeFailed(let url, let error):
            "Couldn't save \(url.path): \(error.localizedDescription)"
        case .unexpectedFile(let url):
            "Refused to save an unexpected rule file at \(url.path)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidPattern:
            "Use an absolute path, a ~/ path, or a path relative to your home directory."
        case .invalidRule, .readFailed:
            "Fix the file at the displayed path, then reload it. Existing content was not changed."
        case .writeFailed:
            "Check the file and home-directory permissions, then try again. Existing content was not changed."
        case .unexpectedFile:
            "Reload the rule files from Settings before saving again."
        }
    }
}

struct UserProtectionRuleStore {
    typealias ReadContents = (URL) throws -> String
    typealias WriteContents = (String, URL) throws -> Void

    let homeURL: URL
    private let fileManager: FileManager
    private let readContents: ReadContents
    private let writeContents: WriteContents

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.init(
            homeURL: homeURL,
            fileManager: fileManager,
            readContents: { try String(contentsOf: $0, encoding: .utf8) },
            writeContents: { contents, url in
                try contents.write(to: url, atomically: true, encoding: .utf8)
            }
        )
    }

    init(
        homeURL: URL,
        fileManager: FileManager,
        readContents: @escaping ReadContents,
        writeContents: @escaping WriteContents
    ) {
        self.homeURL = homeURL
        self.fileManager = fileManager
        self.readContents = readContents
        self.writeContents = writeContents
    }

    func load(_ kind: UserProtectionRuleKind) throws -> UserProtectionRuleDocument {
        let fileURL = homeURL.appending(path: kind.filename)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty(kind: kind, homeURL: homeURL)
        }

        do {
            return try UserProtectionRuleDocument(
                kind: kind,
                fileURL: fileURL,
                contents: readContents(fileURL)
            )
        } catch let error as UserProtectionRuleFileError {
            throw error
        } catch {
            throw UserProtectionRuleFileError.readFailed(fileURL, error)
        }
    }

    func save(_ document: UserProtectionRuleDocument) throws {
        let expectedURL = homeURL.appending(path: document.kind.filename).standardizedFileURL
        guard document.fileURL.standardizedFileURL == expectedURL else {
            throw UserProtectionRuleFileError.unexpectedFile(document.fileURL)
        }

        do {
            try writeContents(document.renderedContents, expectedURL)
        } catch {
            throw UserProtectionRuleFileError.writeFailed(expectedURL, error)
        }
    }
}

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
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let entry = try? UserProtectionRuleDocument.parseEntry(rawLine)
            else { return nil }

            let expanded = expand(entry.pattern, homeURL: homeURL)
            let standardized = URL(fileURLWithPath: expanded).standardized.path
            let normalized = SafetyChecker.caseNormalized(
                standardized.count > 1 && standardized.hasSuffix("/")
                    ? String(standardized.dropLast())
                    : standardized
            )
            let hasGlob = normalized.contains("*") || normalized.contains("?")

            return Rule(
                pattern: entry.pattern,
                normalizedPattern: normalized,
                regex: hasGlob ? globRegex(normalized) : nil,
                isException: entry.isException
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
