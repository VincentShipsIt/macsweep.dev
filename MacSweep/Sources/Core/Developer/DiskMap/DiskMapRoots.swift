import Darwin
import Foundation

enum DiskMapRoots {
    static func known(home: URL) -> [DiskMapRoot] {
        var roots: [DiskMapRoot] = []
        func add(_ paths: [String], _ kind: DiskMapKind, _ owner: DiskMapOwner?) {
            roots += paths.map { DiskMapRoot(url: home.appending(path: $0), kind: kind, owner: owner) }
        }
        add(
            [
                ".npm", ".pnpm-store", ".yarn/cache", ".cache/pip", ".cache/uv", ".cargo/registry", ".cargo/git",
                ".gradle/caches", ".m2/repository", "Library/Caches/Homebrew", "Library/Caches/pnpm",
                "Library/Caches/Yarn", "Library/Caches/pip", "Library/Caches/uv"
            ], .cache, .packageManagers)
        add(["Library/Caches/JetBrains"], .cache, .editorCaches)
        add(
            [
                ".nvm/versions", ".pyenv/versions", ".asdf/installs", ".local/share/mise/installs",
                ".rustup/toolchains", "Library/Developer/Toolchains", "Applications/Xcodes"
            ], .toolchain, .toolchains)
        add(["Library/Developer/CoreSimulator", "Library/Developer/Xcode/iOS DeviceSupport"], .simulator, .xcode)
        add(["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives"], .generated, .xcode)
        add(
            [
                ".docker", ".colima", ".local/share/containers", "Library/Containers/com.docker.docker",
                "Library/Group Containers/group.com.docker", "Parallels", "Virtual Machines.localized",
                "Library/Application Support/OrbStack", "Library/Application Support/UTM"
            ], .vmData, .virtualMachines)
        if home == FileManager.default.homeDirectoryForCurrentUser {
            let applications = URL(fileURLWithPath: "/Applications")
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: applications, includingPropertiesForKeys: nil) {
                roots += entries.filter { $0.lastPathComponent.hasPrefix("Xcode") && $0.pathExtension == "app" }
                    .map { DiskMapRoot(url: $0, kind: .toolchain, owner: .toolchains) }
            }
            roots.append(DiskMapRoot(url: URL(fileURLWithPath: "/private/var/vm"), kind: .swap))
        }
        return roots
    }

    static func projects(home: URL) -> [URL] {
        [
            "Developer", "Projects", "Code", "src", "www", "worktrees", ".codex/worktrees", ".claude/worktrees",
            ".agents/worktrees", ".grok/worktrees", ".t3/worktrees"
        ].map { home.appending(path: $0) }
    }

    /// macOS exposes these fixed system aliases; other symlinked roots remain excluded.
    static func physicalSystemAlias(_ url: URL) -> URL {
        for prefix in ["/var", "/tmp", "/etc"] where url.path == prefix || url.path.hasPrefix(prefix + "/") {
            if let resolved = realpath(prefix, nil) {
                defer { free(resolved) }
                if String(cString: resolved) == "/private" + prefix {
                    return URL(fileURLWithPath: "/private" + url.path)
                }
            }
        }
        return url
    }

    static func contains(_ root: URL, _ node: URL) -> Bool {
        let path = root.standardizedFileURL.path
        let candidate = node.standardizedFileURL.path
        return candidate == path || candidate.hasPrefix(path + "/")
    }

    /// Prefer an explicit parent over an overlapping child; hard links are deduplicated by the measuring walk.
    static func disjoint(_ roots: [DiskMapRoot]) -> [DiskMapRoot] {
        var result: [DiskMapRoot] = []
        for root in roots.sorted(by: { $0.url.path.count < $1.url.path.count })
        where !result.contains(where: { contains($0.url, root.url) }) {
            result.append(root)
        }
        return result
    }
}
