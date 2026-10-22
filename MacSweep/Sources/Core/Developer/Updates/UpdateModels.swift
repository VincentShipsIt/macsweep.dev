import Foundation

enum UpdateSource: String, CaseIterable, Sendable {
    case brewFormula, brewCask, mas, npm, pnpm, pipx, gem

    var title: String {
        switch self {
        case .brewFormula: return "Homebrew Formulae"
        case .brewCask: return "Homebrew Casks"
        case .mas: return "Mac App Store"
        case .npm: return "npm Globals"
        case .pnpm: return "pnpm Globals"
        case .pipx: return "pipx Applications"
        case .gem: return "RubyGems"
        }
    }

    var tool: String {
        switch self {
        case .brewFormula, .brewCask: return "brew"
        default: return rawValue
        }
    }

    var installHint: String {
        switch self {
        case .mas: return "Install mas with Homebrew to list App Store updates. Sign in using the App Store app."
        case .brewFormula, .brewCask: return "Install Homebrew to check this source."
        default: return "Install \(tool) to check this source."
        }
    }
}

struct UpdateCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]

    var preview: String {
        ([executable] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
    }
}

struct UpdateVersion: Sendable {
    let identifier: String
    let title: String
    let current: String
    let latest: String
    var retainedReason: String?
}

struct PackageUpdate: Identifiable, Sendable {
    var id: String { source.rawValue + "|" + version.identifier }
    let source: UpdateSource
    let version: UpdateVersion
    let command: UpdateCommand
    let manager: URL
    let executableIdentity: DevArtifactIdentity?
    let executableStamp: DevArtifactNode?
    let writableRoots: [URL]
    let rootIdentities: [DevArtifactIdentity]
    let blockedReason: String?
    var requiresAdministrator: Bool { source == .mas }
    var isEligible: Bool { blockedReason == nil && executableIdentity != nil }
}

struct UpdateSourceReport: Identifiable, Sendable {
    var id: UpdateSource { source }
    let source: UpdateSource
    let message: String
    let isError: Bool
}

struct UpdateOutcome: Identifiable, Sendable {
    var id: String { update.id }
    let update: PackageUpdate
    let succeeded: Bool
    let message: String
}

/// Root execution accepts an integer App Store ID, never a shell fragment.
struct MasUpdateRequest: Sendable {
    let executable: String
    let appID: UInt64
    let executableIdentity: DevArtifactIdentity
    let executableStamp: DevArtifactNode
}

typealias UpdateCommandRunner = @Sendable (UpdateCommand, TimeInterval) async throws -> ProcessResult
typealias UpdateStreamingRunner =
    @Sendable (UpdateCommand, @escaping ProcessOutputHandler) async throws -> ProcessResult
typealias MasAdministratorUpdate =
    @Sendable (MasUpdateRequest, @escaping ProcessOutputHandler) async throws -> ProcessResult

struct UpdateInventory: Sendable {
    var packages: [PackageUpdate] = []
    var reports: [UpdateSourceReport] = []
}
