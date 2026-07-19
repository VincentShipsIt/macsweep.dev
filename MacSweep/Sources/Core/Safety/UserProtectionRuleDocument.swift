import Foundation

enum UserProtectionRuleKind: String, CaseIterable, Identifiable, Sendable {
    case ignore
    case protect

    var id: Self { self }

    var filename: String {
        switch self {
        case .ignore: UserProtectionRules.ignoreFilename
        case .protect: UserProtectionRules.protectFilename
        }
    }

    var title: String {
        switch self {
        case .ignore: "Scan exclusions"
        case .protect: "Protected paths"
        }
    }

    var behaviorDescription: String {
        switch self {
        case .ignore:
            "Excluded paths do not appear in scans and cannot be cleaned."
        case .protect:
            "Protected paths stay visible for review but cannot be cleaned."
        }
    }
}

struct UserProtectionRuleDocument: Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        var pattern: String
        var isException: Bool

        init(id: UUID = UUID(), pattern: String, isException: Bool = false) {
            self.id = id
            self.pattern = pattern
            self.isException = isException
        }
    }

    private enum Line: Sendable {
        case blank(String)
        case comment(String)
        case rule(Entry)
    }

    let kind: UserProtectionRuleKind
    let fileURL: URL
    private var lines: [Line]

    var entries: [Entry] {
        lines.compactMap { line in
            guard case .rule(let entry) = line else { return nil }
            return entry
        }
    }

    init(kind: UserProtectionRuleKind, fileURL: URL, contents: String) throws {
        self.kind = kind
        self.fileURL = fileURL
        self.lines = try Self.parseLines(contents)
    }

    private init(kind: UserProtectionRuleKind, fileURL: URL, lines: [Line]) {
        self.kind = kind
        self.fileURL = fileURL
        self.lines = lines
    }

    static func empty(kind: UserProtectionRuleKind, homeURL: URL) -> Self {
        Self(
            kind: kind,
            fileURL: homeURL.appending(path: kind.filename),
            lines: []
        )
    }

    static func validationMessage(for entry: Entry) -> String? {
        do {
            _ = try validatedPattern(entry.pattern)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    mutating func replaceEntries(_ entries: [Entry]) throws {
        let validatedEntries = try entries.map { entry in
            Entry(
                id: entry.id,
                pattern: try Self.validatedPattern(entry.pattern),
                isException: entry.isException
            )
        }
        var entriesByID: [Entry.ID: Entry] = [:]
        for entry in validatedEntries {
            entriesByID[entry.id] = entry
        }
        var retainedIDs: Set<Entry.ID> = []
        var updatedLines: [Line] = []

        for line in lines {
            switch line {
            case .rule(let existing):
                guard let replacement = entriesByID[existing.id] else { continue }
                updatedLines.append(.rule(replacement))
                retainedIDs.insert(existing.id)
            case .blank, .comment:
                updatedLines.append(line)
            }
        }

        let additions = validatedEntries.filter { !retainedIDs.contains($0.id) }
        if !additions.isEmpty,
           case .blank(let trailingWhitespace)? = updatedLines.last,
           trailingWhitespace.isEmpty {
            updatedLines.removeLast()
            updatedLines.append(contentsOf: additions.map(Line.rule))
            updatedLines.append(.blank(""))
        } else {
            updatedLines.append(contentsOf: additions.map(Line.rule))
        }

        lines = updatedLines
    }

    var renderedContents: String {
        lines.map { line in
            switch line {
            case .blank(let raw), .comment(let raw):
                raw
            case .rule(let entry):
                (entry.isException ? "!" : "") + entry.pattern
            }
        }
        .joined(separator: "\n")
    }

    static func parseEntry(_ rawLine: String) throws -> Entry {
        var candidate = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let isException = candidate.hasPrefix("!")
        if isException {
            candidate.removeFirst()
        }
        return Entry(
            pattern: try validatedPattern(candidate),
            isException: isException
        )
    }

    private static func parseLines(_ contents: String) throws -> [Line] {
        let normalizedContents = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalizedContents.isEmpty else { return [] }

        return try normalizedContents
            .components(separatedBy: "\n")
            .enumerated()
            .map { index, rawLine in
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return .blank(rawLine)
                }
                if trimmed.hasPrefix("#") {
                    return .comment(rawLine)
                }

                do {
                    return .rule(try parseEntry(rawLine))
                } catch {
                    throw UserProtectionRuleFileError.invalidRule(
                        line: index + 1,
                        reason: error.localizedDescription
                    )
                }
            }
    }

    private static func validatedPattern(_ rawPattern: String) throws -> String {
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            throw UserProtectionRuleFileError.invalidPattern(
                "Enter an absolute, ~/ or home-relative path."
            )
        }
        guard !pattern.hasPrefix("#") else {
            throw UserProtectionRuleFileError.invalidPattern(
                "Rules cannot begin with # because that marks a comment."
            )
        }
        guard !pattern.hasPrefix("!") else {
            throw UserProtectionRuleFileError.invalidPattern(
                "Use the exception toggle instead of adding ! to the path."
            )
        }
        guard !pattern.contains("\n"), !pattern.contains("\r"), !pattern.contains("\0") else {
            throw UserProtectionRuleFileError.invalidPattern(
                "Rules must contain exactly one text line."
            )
        }
        return pattern
    }
}
