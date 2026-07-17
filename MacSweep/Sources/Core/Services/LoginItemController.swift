import Foundation

/// Mutation companion to `LoginItemEnumerator`. Ports the enable/disable/delete
/// paths from the GUI-only `LoginItemsService` into Core so the headless/CLI
/// surface can toggle and remove launch agents / launch daemons.
///
/// Items are identified by their launchd `Label` — the same string
/// `LoginItemEnumerator` surfaces as `name`. Rather than assuming the plist
/// filename equals the Label (the GUI's fragile `name + ".plist"` shortcut, which
/// silently no-ops when an agent's file is named differently from its Label),
/// this scans the LaunchAgents / LaunchDaemons directories and matches each
/// plist's *parsed* `Label`. That is the root-cause-correct resolution.
///
/// SMAppService ("appService") items have no editable plist in these directories
/// — they are managed by their owning app through SMAppService — so a label that
/// resolves to no plist is reported as not-found rather than silently ignored.
actor LoginItemController {
    private let userLaunchAgents: URL
    private let systemLaunchAgents: URL
    private let systemLaunchDaemons: URL

    /// Directories are injectable so tests can point the controller at synthetic
    /// plist fixtures in a temp dir. The defaults reproduce the previous
    /// hardcoded production paths, so existing no-arg callers are unaffected.
    init(
        userLaunchAgents: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents"),
        systemLaunchAgents: URL = URL(fileURLWithPath: "/Library/LaunchAgents"),
        systemLaunchDaemons: URL = URL(fileURLWithPath: "/Library/LaunchDaemons")
    ) {
        self.userLaunchAgents = userLaunchAgents
        self.systemLaunchAgents = systemLaunchAgents
        self.systemLaunchDaemons = systemLaunchDaemons
    }

    enum MutationError: Error {
        /// No plist in any searched directory has a matching Label.
        case notFound
        /// More than one plist matched the Label (e.g. user + system copy).
        case ambiguous([String])
        /// Read/serialize/write/trash failed.
        case failed(String)
    }

    struct Outcome {
        let label: String
        let plistPath: String
        let kind: HeadlessLoginItemKind
        /// Resulting enabled state for enable/disable; `false` for remove.
        let enabled: Bool
        let removed: Bool
    }

    // MARK: - Mutations

    /// Set the `Disabled` key in the matched plist. launchd treats a missing or
    /// `false` `Disabled` as enabled, so disabling writes `Disabled = true`.
    func setEnabled(_ enabled: Bool, label: String) throws -> Outcome {
        let match = try locate(label: label)

        // Capture the plist's on-disk format so we can write it back unchanged.
        // Reading with `format: nil` always succeeds for either xml or binary, but
        // unconditionally re-serializing as `.xml` would silently convert a binary
        // plist; round-tripping through the captured format preserves it.
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: match.url),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        else {
            throw MutationError.failed("Could not read plist at \(match.url.path).")
        }

        plist["Disabled"] = !enabled

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0) else {
            throw MutationError.failed("Could not serialize plist at \(match.url.path).")
        }

        do {
            try newData.write(to: match.url)
        } catch {
            throw MutationError.failed(error.localizedDescription)
        }

        return Outcome(label: label, plistPath: match.url.path, kind: match.kind, enabled: enabled, removed: false)
    }

    /// Move the matched plist to the Trash (recoverable), mirroring the
    /// `trashItem` convention used across the cleanup modules rather than a
    /// hard `removeItem`.
    func remove(label: String) throws -> Outcome {
        let match = try locate(label: label)

        do {
            try CleanupFileRemover.recoverable(match.url, module: "login-items")
        } catch {
            throw MutationError.failed(error.localizedDescription)
        }

        return Outcome(label: label, plistPath: match.url.path, kind: match.kind, enabled: false, removed: true)
    }

    // MARK: - Resolution

    /// Resolve a launchd Label to the single plist that declares it, parsing each
    /// plist's `Label` (falling back to the filename, matching the enumerator).
    ///
    /// launchd Labels are case-sensitive identifiers, so we match exactly first and
    /// only fall back to a case-insensitive pass when no exact match exists — an
    /// exact match must never be shadowed by a differently-cased plist.
    ///
    /// This also scopes resolution to *real launchd plists* in the LaunchAgents /
    /// LaunchDaemons directories. SMAppService ("appService") items live in a
    /// different identity namespace (their SMAppService display `name`) and have no
    /// editable plist here, so they cannot be mutated through this path. The only
    /// residual risk is a launchd Label that *coincidentally* equals an appService
    /// name; exact-Label matching above is the mitigation that minimizes it.
    private func locate(label: String) throws -> (url: URL, kind: HeadlessLoginItemKind) {
        let searchOrder: [(URL, HeadlessLoginItemKind)] = [
            (userLaunchAgents, .launchAgent),
            (systemLaunchAgents, .launchAgent),
            (systemLaunchDaemons, .launchDaemon)
        ]

        var exactMatches: [(url: URL, kind: HeadlessLoginItemKind)] = []
        var caseInsensitiveMatches: [(url: URL, kind: HeadlessLoginItemKind)] = []
        for (directory, kind) in searchOrder {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }

            for url in files where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }

                let plistLabel = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
                if plistLabel == label {
                    exactMatches.append((url, kind))
                } else if plistLabel.caseInsensitiveCompare(label) == .orderedSame {
                    caseInsensitiveMatches.append((url, kind))
                }
            }
        }

        // Prefer exact matches; only consult the case-insensitive pass when no
        // exact-cased plist declares the Label.
        let matches = exactMatches.isEmpty ? caseInsensitiveMatches : exactMatches

        if matches.isEmpty { throw MutationError.notFound }
        if matches.count > 1 { throw MutationError.ambiguous(matches.map { $0.url.path }) }
        return matches[0]
    }
}
