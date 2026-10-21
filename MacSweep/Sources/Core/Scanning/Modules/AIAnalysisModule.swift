import Foundation

struct AIAnalysisModule: ScanModule {
    let id = "ai-analysis"
    let name = "AI Analysis"
    let description = "Review manually selected cache suggestions"
    let icon = "brain.head.profile"

    func scan() async throws -> [CleanupItem] { [] }

    static func prepare(_ findings: [CacheFinding]) async throws -> [CleanupItem] {
        var items: [CleanupItem] = []
        for finding in findings {
            let path = URL(fileURLWithPath: finding.path.expandingTilde)
            let values = try path.scanResourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let type: CleanupItem.ItemType = values.isSymbolicLink == true ? .symbolicLink
                : values.isDirectory == true ? .directory : .file
            items.append(CleanupItem(
                id: finding.id, path: path, size: try await DiskAnalyzer.size(of: path),
                type: type, module: "ai-analysis", moduleName: "AI Analysis"
            ))
        }
        return items
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.recoverable(item.path, module: item.module)
        }
    }
}
