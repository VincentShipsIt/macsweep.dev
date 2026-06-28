import Foundation

/// Module for finding and cleaning mail attachments
struct MailAttachmentsModule: ScanModule {
    let id = "mail-attachments"
    let name = "Mail Attachments"
    let description = "Find downloaded email attachments"
    let icon = "envelope"

    /// Minimum file size to report (1MB default)
    var threshold: Int64 = 1_048_576

    /// Minimum age in days: only report attachments at least this many days old.
    /// nil = no minimum (all files included). The filter keeps OLDER files, so the
    /// name reflects the actual behaviour.
    var minAgeDays: Int? = nil

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        let attachmentLocations = getAttachmentLocations()

        for location in attachmentLocations {
            let found = await scanLocation(location)
            items.append(contentsOf: found)
        }

        // Remove duplicates (same file, different path due to symlinks)
        let uniqueItems = Dictionary(grouping: items, by: { $0.path.standardizedFileURL.path })
            .compactMapValues { $0.first }
            .values

        return Array(uniqueItems).sorted { $0.size > $1.size }
    }

    private func getAttachmentLocations() -> [AttachmentLocation] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appending(path: "Library")

        var locations: [AttachmentLocation] = []

        // Apple Mail Downloads
        locations.append(AttachmentLocation(
            path: library.appending(path: "Mail Downloads"),
            source: "Apple Mail"
        ))

        // Apple Mail Container
        locations.append(AttachmentLocation(
            path: library.appending(path: "Containers/com.apple.mail/Data/Library/Mail Downloads"),
            source: "Apple Mail"
        ))

        // Mail message attachments (embedded in messages). The Mail data
        // directory is version-stamped (V8, V9, V10, V11, …) and bumps with
        // each macOS release, so hardcoding one version misses everyone on a
        // different OS. Enumerate every V<number> dir present instead.
        let mailRoot = library.appending(path: "Mail")
        if let mailVersions = try? FileManager.default.contentsOfDirectory(
            at: mailRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for versionDir in mailVersions {
                let name = versionDir.lastPathComponent
                guard name.hasPrefix("V"), Int(name.dropFirst()) != nil else { continue }
                locations.append(AttachmentLocation(
                    path: versionDir,
                    source: "Apple Mail (Embedded)",
                    filePatterns: ["Attachments"]
                ))
            }
        }

        // Outlook attachments
        locations.append(AttachmentLocation(
            path: library.appending(path: "Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles"),
            source: "Microsoft Outlook"
        ))

        // Outlook modern
        locations.append(AttachmentLocation(
            path: library.appending(path: "Containers/com.microsoft.Outlook/Data/Library/Caches"),
            source: "Microsoft Outlook"
        ))

        // Spark
        locations.append(AttachmentLocation(
            path: library.appending(path: "Containers/com.readdle.smartemail-Mac/Data/Library/Application Support/Spark/Attachments"),
            source: "Spark"
        ))

        // Airmail
        locations.append(AttachmentLocation(
            path: library.appending(path: "Containers/it.bloop.airmail2/Data/Library/Application Support/Airmail"),
            source: "Airmail"
        ))

        // Thunderbird
        let thunderbirdProfiles = library.appending(path: "Thunderbird/Profiles")
        if FileManager.default.fileExists(atPath: thunderbirdProfiles.path) {
            if let profiles = try? FileManager.default.contentsOfDirectory(at: thunderbirdProfiles, includingPropertiesForKeys: nil) {
                for profile in profiles {
                    locations.append(AttachmentLocation(
                        path: profile.appending(path: "ImapMail"),
                        source: "Thunderbird"
                    ))
                }
            }
        }

        return locations
    }

    private func scanLocation(_ location: AttachmentLocation) async -> [CleanupItem] {
        var items: [CleanupItem] = []

        guard FileManager.default.fileExists(atPath: location.path.path) else { return [] }

        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: location.path,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            do {
                let values = try url.resourceValues(forKeys: resourceKeys)

                // Skip directories and symlinks
                guard values.isDirectory == false,
                      values.isSymbolicLink == false
                else { continue }

                // Check file patterns if specified
                if let patterns = location.filePatterns {
                    let matches = patterns.contains { pattern in
                        url.path.contains(pattern)
                    }
                    if !matches { continue }
                }

                // Get file size
                let size = values.diskSize
                guard size >= threshold else { continue }

                // Check age if specified
                if let minDays = minAgeDays,
                   let modified = values.contentModificationDate {
                    let daysOld = Calendar.current.dateComponents([.day], from: modified, to: Date()).day ?? 0
                    if daysOld < minDays { continue }
                }

                // Skip mail database files
                let ext = url.pathExtension.lowercased()
                if ["emlx", "emlxpart", "mbox", "partial"].contains(ext) { continue }

                // Determine attachment type
                let attachmentType = classifyAttachment(url: url)

                items.append(CleanupItem(
                    id: UUID(),
                    path: url,
                    size: size,
                    type: .file,
                    module: id,
                    moduleName: "\(location.source) - \(attachmentType)",
                    lastModified: values.contentModificationDate
                ))

            } catch {
                continue
            }
        }

        return items
    }

    private func classifyAttachment(url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return "Documents"
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key":
            return "Documents"
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp":
            return "Images"
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
            return "Videos"
        case "mp3", "m4a", "wav", "aac", "flac":
            return "Audio"
        case "zip", "rar", "7z", "tar", "gz", "dmg":
            return "Archives"
        default:
            return "Other"
        }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []
        let checker = SafetyChecker()

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
            } else {
                // Defense-in-depth: re-validate every item before deleting,
                // even though scan() already filtered to safe paths.
                guard checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe else {
                    errors.append(CleanupError(
                        path: item.path,
                        message: "Blocked by safety checks"
                    ))
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(
                        path: item.path,
                        message: error.localizedDescription,
                        underlyingError: error
                    ))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

// MARK: - Attachment Location

struct AttachmentLocation {
    let path: URL
    let source: String
    var filePatterns: [String]? = nil
}

// MARK: - Mail Statistics

struct MailStats {
    let totalAttachments: Int
    let totalSize: Int64
    let bySource: [String: (count: Int, size: Int64)]
    let byType: [String: (count: Int, size: Int64)]

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    static func from(items: [CleanupItem]) -> MailStats {
        var bySource: [String: (count: Int, size: Int64)] = [:]
        var byType: [String: (count: Int, size: Int64)] = [:]

        for item in items {
            let parts = item.moduleName.split(separator: " - ")
            let source = parts.first.map(String.init) ?? "Unknown"
            let type = parts.last.map(String.init) ?? "Other"

            let sourceStats = bySource[source] ?? (0, 0)
            bySource[source] = (sourceStats.0 + 1, sourceStats.1 + item.size)

            let typeStats = byType[type] ?? (0, 0)
            byType[type] = (typeStats.0 + 1, typeStats.1 + item.size)
        }

        return MailStats(
            totalAttachments: items.count,
            totalSize: items.reduce(0) { $0 + $1.size },
            bySource: bySource,
            byType: byType
        )
    }
}
