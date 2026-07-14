import Foundation

struct SmartCareFinding: Identifiable, Hashable, Sendable {
    let moduleID: String
    let title: String
    let itemCount: Int
    let reclaimableBytes: Int64
    let autoCleanRecommended: Bool

    var id: String { moduleID }

    var formattedBytes: String {
        reclaimableBytes.formattedFileSize
    }
}

struct SmartCareSummary: Sendable {
    let score: Int
    let reclaimableBytes: Int64
    let issueCount: Int
    let findings: [SmartCareFinding]
    let recommendedCleanupItemIDs: Set<CleanupItem.ID>

    var formattedBytes: String {
        reclaimableBytes.formattedFileSize
    }

    var recommendedFindings: [SmartCareFinding] {
        findings.filter(\.autoCleanRecommended)
    }

    var reviewRequiredFindings: [SmartCareFinding] {
        findings.filter { !$0.autoCleanRecommended }
    }
}

enum SmartCareDefaults {
    static let moduleIDs = [
        "system-cache",
        "trash-bins",
        "mail-attachments",
        "dev-tools",
        "large-files",
        "duplicates",
        "similar-photos",
        "cloud-cleanup",
    ]

    static let autoCleanModules: Set<String> = [
        "system-cache",
        "trash-bins",
        "mail-attachments",
        "dev-tools",
        "cloud-cleanup",
    ]
}

struct SmartCareAnalyzer {
    func summarize(items: [CleanupItem], diskUsage: DiskUsage?) -> SmartCareSummary {
        let grouped = Dictionary(grouping: items, by: \.module)

        let findings = grouped.map { moduleID, moduleItems in
            SmartCareFinding(
                moduleID: moduleID,
                title: title(for: moduleID),
                itemCount: moduleItems.count,
                reclaimableBytes: moduleItems.reduce(0) { $0 + $1.size },
                autoCleanRecommended: SmartCareDefaults.autoCleanModules.contains(moduleID)
                    && moduleItems.contains { $0.cleanupReviewReason == nil }
            )
        }
        .sorted { lhs, rhs in
            if lhs.reclaimableBytes == rhs.reclaimableBytes {
                return lhs.itemCount > rhs.itemCount
            }
            return lhs.reclaimableBytes > rhs.reclaimableBytes
        }

        let totalBytes = findings.reduce(0) { $0 + $1.reclaimableBytes }
        let issueCount = findings.reduce(0) { $0 + $1.itemCount }
        let recommendedIDs = Set(items.filter {
            SmartCareDefaults.autoCleanModules.contains($0.module)
                && $0.cleanupReviewReason == nil
        }.map(\.id))

        return SmartCareSummary(
            score: score(for: findings, totalBytes: totalBytes, diskUsage: diskUsage),
            reclaimableBytes: totalBytes,
            issueCount: issueCount,
            findings: findings,
            recommendedCleanupItemIDs: recommendedIDs
        )
    }

    private func title(for moduleID: String) -> String {
        switch moduleID {
        case "system-cache": return "System Junk"
        case "trash-bins": return "Trash Bins"
        case "mail-attachments": return "Mail Attachments"
        case "dev-tools": return "Developer Tools"
        case "large-files": return "Large Files"
        case "duplicates": return "Duplicate Files"
        case "similar-photos": return "Similar Photos"
        case "cloud-cleanup": return "Cloud Cleanup"
        case AssistantWatchlistModule.moduleID: return "Assistant Watchlists"
        default: return moduleID.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private func score(
        for findings: [SmartCareFinding],
        totalBytes: Int64,
        diskUsage: DiskUsage?
    ) -> Int {
        var score = 100

        if let usage = diskUsage {
            if usage.freePercentage < 0.08 {
                score -= 28
            } else if usage.freePercentage < 0.15 {
                score -= 18
            } else if usage.freePercentage < 0.25 {
                score -= 8
            }
        }

        score -= min(24, findings.reduce(0) { $0 + min(4, $1.itemCount) })

        let reclaimableGB = Double(totalBytes) / 1_073_741_824
        score -= min(24, Int((reclaimableGB * 3.5).rounded(.up)))

        if findings.contains(where: { !$0.autoCleanRecommended }) {
            score -= 6
        }

        return max(25, min(100, score))
    }
}
