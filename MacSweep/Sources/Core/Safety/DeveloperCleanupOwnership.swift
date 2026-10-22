import Foundation

/// Installed runtimes and persistent native environments cannot be treated as
/// disposable data just because a descendant is named Cache, build or target.
enum DeveloperCleanupOwner: String, Sendable {
    case xcode = "Xcode Deep Clean"
    case toolchains = "Toolchains"
    case virtualMachines = "Virtual Machines"
}

enum DeveloperCleanupOwnership {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
    private static let roots: [(DeveloperCleanupOwner, String)] = {
        let entries: [(DeveloperCleanupOwner, [String])] = [
            (.xcode, ["Library/Developer/Xcode", "Library/Developer/CoreSimulator"]),
            (
                .toolchains,
                [
                    ".nvm/versions", ".pyenv/versions", ".rbenv/versions", ".asdf/installs",
                    ".local/share/mise/installs", ".rustup/toolchains", ".jdks"
                ]
            ),
            (
                .virtualMachines,
                [
                    ".orbstack/data", ".colima", ".lima", ".docker/desktop", ".vagrant.d/boxes",
                    "VirtualBox VMs", "Parallels", "Documents/Parallels", "Documents/UTM",
                    "Library/Containers/com.utmapp.UTM/Data/Documents",
                    "Library/Containers/com.utmapp.UTM.UTM/Data/Documents",
                    "Library/Containers/com.docker.docker/Data/vms",
                    "Library/Application Support/Claude/vm_bundles",
                    "Library/Application Support/Claude/claude-code-vm",
                    "Library/Application Support/Claude/local-agent-mode-sessions"
                ]
            )
        ]
        return entries.flatMap { owner, paths in
            paths.map { (owner, SafetyChecker.caseNormalized(home.appending(path: $0).path)) }
        }
    }()

    static func owner(of url: URL, includingAncestors: Bool = true) -> DeveloperCleanupOwner? {
        let path = SafetyChecker.caseNormalized(url.standardizedFileURL.path)
        if let match = roots.first(where: { _, root in
            path == root || path.hasPrefix(root + "/") || (includingAncestors && root.hasPrefix(path + "/"))
        }) {
            return match.0
        }
        let base = SafetyChecker.caseNormalized(home.path) + "/"
        if path.hasPrefix(base),
            url.pathComponents.contains(where: {
                ["utm", "pvm"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
            }) {
            return .virtualMachines
        }
        return nil
    }

    static func reason(_ owner: DeveloperCleanupOwner) -> String {
        "Persistent or manager-owned data requires the verified \(owner.rawValue) workflow."
    }
}
