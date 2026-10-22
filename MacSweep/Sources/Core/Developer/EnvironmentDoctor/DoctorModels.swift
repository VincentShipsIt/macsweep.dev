import Foundation

public struct HeadlessDoctorReport: Codable, Sendable {
    public let findings: [HeadlessDoctorFinding]
    public let issues: [String]
}

public struct HeadlessDoctorFinding: Codable, Sendable {
    public let category: String
    public let severity: String
    public let path: String?
    public let evidence: String
    public let remediation: String
    public let requiresAdministrator: Bool
    public let canRepair: Bool
}

enum DoctorCategory: String, CaseIterable, Sendable {
    case launchItems = "Orphaned Launch Items"
    case links = "Broken Symlinks"
    case path = "Login PATH"
    case homebrew = "Homebrew Doctor"
}

enum DoctorRepair: Equatable, Sendable {
    case orphanedLaunchItem(program: String)
    case brokenLink(destination: String)
}

struct DoctorFinding: Identifiable, Sendable {
    var id: String { "\(category.rawValue):\(path?.path ?? evidence)" }
    let reviewID = UUID()
    let category: DoctorCategory
    let path: URL?
    let evidence: String
    let remediation: String
    let requiresAdministrator: Bool
    var retentionReason: String?
    let repair: DoctorRepair?
    let stamp: DevArtifactNode?
    var canRepair: Bool { repair != nil && stamp != nil && retentionReason == nil }
    var preview: CleanupItem? {
        guard let path else { return nil }
        return CleanupItem(
            id: reviewID, path: path, size: max(0, stamp?.size ?? 0), type: .file,
            module: "environment-doctor", moduleName: category.rawValue,
            cleanupReviewReason: "Move this exact orphaned plist or broken link to Trash. "
                + (requiresAdministrator ? "Administrator authorization is required." : "Review before removal."))
    }
}

struct DoctorInventory: Sendable {
    var findings: [DoctorFinding] = []
    var issues: [String] = []
    var report: HeadlessDoctorReport {
        HeadlessDoctorReport(
            findings: findings.map {
                HeadlessDoctorFinding(
                    category: $0.category.rawValue, severity: "warning", path: $0.path?.path,
                    evidence: $0.evidence, remediation: $0.remediation,
                    requiresAdministrator: $0.requiresAdministrator, canRepair: $0.canRepair)
            }, issues: issues)
    }
}

typealias DoctorCommandRunner = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult

struct DoctorPaths: Sendable {
    let home: URL
    let launchDirectories: [URL]
    let binDirectories: [URL]
    let shell: String
    let brew: String?

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchDirectories: [URL]? = nil, binDirectories: [URL]? = nil,
        shell: String? = nil, brew: String? = HomebrewPaths.brewPath
    ) {
        self.home = home
        self.launchDirectories =
            launchDirectories ?? [
                home.appendingPathComponent("Library/LaunchAgents"),
                URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")
            ]
        var bins = [
            URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin")
        ]
        if let prefix = HomebrewPaths.prefix { bins.append(URL(fileURLWithPath: prefix + "/bin")) }
        self.binDirectories = binDirectories ?? Array(Set(bins))
        if let shell {
            self.shell = shell
        } else if let entry = getpwuid(getuid()), let value = entry.pointee.pw_shell {
            self.shell = String(cString: value)
        } else {
            self.shell = "/bin/zsh"
        }
        self.brew = brew
    }
}
