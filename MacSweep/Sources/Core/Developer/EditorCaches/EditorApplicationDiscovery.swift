import AppKit
import Darwin
import Foundation

enum EditorApplicationDiscovery {
    static func inventory() async -> EditorApplicationInventory {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.bundleURL) }
        }
        let registered = await MainActor.run {
            jetBrainsBundleIDs.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications"),
            home.appending(path: "Library/Application Support/JetBrains/Toolbox/apps")
        ]
        return await Task.detached(priority: .utility) {
            var result = EditorApplicationInventory(runningIDs: Set(running.compactMap(\.0)))
            do {
                let paths = try applications(in: roots) + running.compactMap(\.1) + registered
                for path in Set(paths) {
                    var metadata = stat()
                    if lstat(path.path, &metadata) != 0, errno == ENOENT { continue }
                    try addApplication(path, to: &result)
                }
            } catch { result.issues.append("Installed IDE inventory incomplete: " + error.localizedDescription) }
            return result
        }.value
    }

    static func addApplication(_ path: URL, to inventory: inout EditorApplicationInventory) throws {
        guard let bundle = Bundle(url: path), let identifier = bundle.bundleIdentifier else {
            throw DevArtifactSafetyError("An application has unreadable bundle metadata.")
        }
        inventory.installedIDs.insert(identifier)
        let metadata = path.appending(path: "Contents/Resources/product-info.json")
        if isJetBrainsProcess(identifier) {
            let json = try EditorCacheMatchers.json(metadata)
            guard let selector = json["dataDirectoryName"] as? String,
                EditorCacheMatchers.jetBrainsSelector(selector)
            else {
                throw DevArtifactSafetyError("Installed IDE cache-directory metadata is unknown.")
            }
            inventory.jetBrainsSelectors.insert(selector)
        }
    }

    static let jetBrainsBundleIDs = [
        "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
        "com.jetbrains.WebStorm", "com.jetbrains.PhpStorm", "com.jetbrains.CLion", "com.jetbrains.datagrip",
        "com.jetbrains.rider", "com.jetbrains.goland", "com.jetbrains.rubymine", "com.jetbrains.RustRover",
        "com.jetbrains.aqua", "com.jetbrains.dataspell"
    ]

    static func isJetBrainsIDE(_ identifier: String) -> Bool {
        jetBrainsBundleIDs.contains { $0.lowercased() == identifier.lowercased() }
    }

    static func isJetBrainsProcess(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        return lower.hasPrefix("com.jetbrains.")
            && [
                "intellij", "pycharm", "webstorm", "phpstorm", "clion",
                "datagrip", "rider", "goland", "rubymine", "rustrover", "aqua", "dataspell"
            ].contains {
                lower.contains($0)
            }
    }

    static func applications(in roots: [URL]) throws -> [URL] {
        var queue = roots
        var visited = Set<String>()
        var applications: [URL] = []
        var count = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while let root = queue.popLast() {
            guard count < 30_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Installed IDE discovery exceeded its budget.")
            }
            let canonical = root.resolvingSymlinksInPath()
            guard visited.insert(canonical.path).inserted else { continue }
            var info = stat()
            if stat(canonical.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw DevArtifactSafetyError("An application directory is inaccessible.")
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            let entries = try FileManager.default.contentsOfDirectory(at: canonical, includingPropertiesForKeys: nil)
            count += entries.count
            guard count <= 30_000 else { throw DevArtifactSafetyError("Installed IDE entry limit exceeded.") }
            for entry in entries {
                if entry.pathExtension == "app" { applications.append(entry) } else { queue.append(entry) }
            }
        }
        return applications
    }
}
