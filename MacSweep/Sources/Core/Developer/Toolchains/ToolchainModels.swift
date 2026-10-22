import Foundation

enum ToolchainManager: String, CaseIterable, Sendable {
    case nvm, pyenv, rbenv, asdf, mise, rustup, java

    var title: String { self == .java ? "JDKs" : rawValue }
}

enum ToolchainStatus: String, Sendable {
    case active, stale, unknown
}

struct ToolchainPolicy: Sendable {
    var staleMonths = 6
    var maximumReferenceEntries = 250_000
    var referenceTimeLimit: TimeInterval = 10

    func cutoff(now: Date) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: -max(1, min(36, staleMonths)), to: now) ?? now
    }
}

struct ToolchainCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]

    var preview: String {
        ([executable] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }
}

struct ToolchainInstallation: Identifiable, Sendable {
    var id: String { manager.rawValue + "|" + tool + "|" + version + "|" + path.path }
    let manager: ToolchainManager
    let tool: String
    let version: String
    let path: URL
    let size: Int64?
    let lastUsedSignal: Date?
    let status: ToolchainStatus
    let evidence: [String]
    let command: ToolchainCommand?
    let identity: DevArtifactIdentity?
    let executableIdentity: DevArtifactIdentity?
    let executableStamp: DevArtifactNode?
    let content: [DevArtifactNode]
    let witnesses: [ToolchainWitness]

    var isSelectable: Bool { status == .stale && command != nil && identity != nil && size != nil }
}

struct ToolchainInventory: Sendable {
    var installations: [ToolchainInstallation] = []
    var issues: [String] = []
    var referenceRoots: [URL] = []
}

struct ToolchainReference: Sendable {
    let manager: ToolchainManager
    let tool: String
    let version: String
    let source: String
}

struct ToolchainReferences: Sendable {
    var values: [ToolchainReference] = []
    var issues: [String] = []
    var unknownManagers = Set<ToolchainManager>()
    var links: [(source: URL, destination: URL)] = []
    var witnesses: [ToolchainWitness] = []

    func evidence(manager: ToolchainManager, tool: String, version: String) -> [String] {
        values.filter { $0.manager == manager && $0.tool == tool && Self.matches($0.version, version: version) }
            .map { "Referenced by \($0.source): \($0.version)" }
    }

    static func matches(_ reference: String, version: String) -> Bool {
        let left = reference.hasPrefix("v") ? String(reference.dropFirst()) : reference
        let right = version.hasPrefix("v") ? String(version.dropFirst()) : version
        if ["node", "stable", "latest", "*", "lts/*", "system"].contains(left) { return true }
        return left == right || right.hasPrefix(left + ".") || right.hasPrefix(left + "-")
    }
}

struct ToolchainLocation: Sendable {
    let manager: ToolchainManager
    let root: URL
    let executable: URL?
}

typealias ToolchainCommandRunner = @Sendable (ToolchainCommand, TimeInterval) async throws -> ProcessResult

struct ToolchainCandidate: Sendable {
    let tool: String
    let version: String
    let path: URL
}

struct ToolchainContent: Sendable {
    let nodes: [DevArtifactNode]
    let size: Int64
    let signal: Date
}

struct ToolchainWitness: Equatable, Sendable {
    let path: String
    let node: DevArtifactNode?
}
