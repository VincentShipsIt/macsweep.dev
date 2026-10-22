import Foundation

enum UpdateCommands {
    static func manager(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { String($0) + "/" + name }
        let candidates: [String?] =
            search.map(Optional.some) + [
                HomebrewPaths.toolPath(name), home.appendingPathComponent(".local/bin/" + name).path,
                home.appendingPathComponent(".npm-global/bin/" + name).path, "/usr/bin/" + name,
                "/opt/local/bin/" + name
            ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func command(_ manager: String, _ arguments: [String], source: UpdateSource) -> UpdateCommand {
        var environment = [
            "-u", "BASH_ENV", "-u", "ENV", "LC_ALL=C", "CI=1", "GIT_TERMINAL_PROMPT=0",
            "SUDO_ASKPASS=/usr/bin/false", "PIP_NO_INPUT=1", "PIP_DISABLE_PIP_VERSION_CHECK=1",
            "PATH=" + nativePath(manager)
        ]
        if source == .brewFormula || source == .brewCask {
            environment += [
                "NONINTERACTIVE=1", "HOMEBREW_NO_SUDO=1", "HOMEBREW_NO_ASK=1",
                "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1"
            ]
        }
        return .init(executable: "/usr/bin/env", arguments: environment + [manager] + arguments)
    }

    private static func nativePath(_ manager: String) -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            URL(fileURLWithPath: manager).deletingLastPathComponent().path,
            environment["PATH"] ?? "/usr/bin:/bin", environment["PNPM_HOME"] ?? "",
            home.appendingPathComponent("Library/pnpm/bin").path,
            home.appendingPathComponent("Library/pnpm").path,
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        return paths.filter { !$0.isEmpty }.joined(separator: ":")
    }

    static func outdated(_ source: UpdateSource, manager: String) -> UpdateCommand {
        let args: [String]
        switch source {
        case .brewFormula, .brewCask: args = ["outdated", "--json=v2"]
        case .mas: args = ["outdated"]
        case .npm: args = ["outdated", "--global", "--json", "--ignore-scripts"]
        case .pnpm: args = ["outdated", "--global", "--format", "json"]
        case .pipx: args = ["list", "--json"]
        case .gem: args = ["outdated", "--norc"]
        }
        return command(manager, args, source: source)
    }

    static func upgrade(_ version: UpdateVersion, source: UpdateSource, manager: String) -> UpdateCommand {
        let args: [String]
        switch source {
        case .brewFormula: args = ["upgrade", "--formula", version.identifier]
        case .brewCask: args = ["upgrade", "--cask", version.identifier]
        case .mas: return .init(executable: manager, arguments: ["upgrade", version.identifier])
        case .npm:
            args = [
                "install", "--global", version.identifier + "@" + version.latest, "--ignore-scripts", "--no-audit",
                "--no-fund"
            ]
        case .pnpm: args = ["add", "--global", version.identifier + "@" + version.latest, "--ignore-scripts"]
        case .pipx: args = ["upgrade", version.identifier, "--pip-args=--no-input --only-binary=:all:"]
        case .gem: args = ["update", version.identifier, "--no-document", "--norc"]
        }
        return command(manager, args, source: source)
    }
}
