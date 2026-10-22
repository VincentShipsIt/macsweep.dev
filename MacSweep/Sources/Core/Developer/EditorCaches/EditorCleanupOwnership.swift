import Foundation

/// Generic cleanup cannot substitute for the editor service's current-version,
/// workspace, extension-registry and running-owner evidence.
enum EditorCleanupOwnership {
    private static let roots: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        var relative = ["Library/Caches/JetBrains", "Library/Application Support/JetBrains"]
        for editor in EditorCacheProduct.editors {
            relative.append("Library/Application Support/\(editor.directory)/User/workspaceStorage")
            relative.append("\(editor.extensionDirectory)/extensions")
        }
        for product in EditorCacheProduct.electron {
            for cache in ["Cache", "Code Cache", "GPUCache"] {
                relative.append("Library/Application Support/\(product.directory)/\(cache)")
            }
        }
        return relative.map { SafetyChecker.caseNormalized(home.appending(path: $0).standardizedFileURL.path) }
    }()

    static func overlaps(_ url: URL) -> Bool {
        let path = SafetyChecker.caseNormalized(url.standardizedFileURL.path)
        return roots.contains { root in
            path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
        }
    }

    static let retentionReason =
        "Review this data in IDE & Editor Caches; its owner and current-version checks are required."
}
