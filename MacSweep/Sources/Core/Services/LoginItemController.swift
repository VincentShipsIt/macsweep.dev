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
    private let userLaunchAgents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    private let systemLaunchAgents = URL(fileURLWithPath: "/Library/LaunchAgents")
    private let systemLaunchDaemons = URL(fileURLWithPath: "/Library/LaunchDaemons")

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

        guard let data = try? Data(contentsOf: match.url),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw MutationError.failed("Could not read plist at \(match.url.path).")
        }

        plist["Disabled"] = !enabled

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
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
            try FileManager.default.trashItem(at: match.url, resultingItemURL: nil)
        } catch {
            throw MutationError.failed(error.localizedDescription)
        }

        return Outcome(label: label, plistPath: match.url.path, kind: match.kind, enabled: false, removed: true)
    }

    // MARK: - Resolution

    /// Resolve a launchd Label to the single plist that declares it, parsing each
    /// plist's `Label` (falling back to the filename, matching the enumerator).
    private func locate(label: String) throws -> (url: URL, kind: HeadlessLoginItemKind) {
        let searchOrder: [(URL, HeadlessLoginItemKind)] = [
            (userLaunchAgents, .launchAgent),
            (systemLaunchAgents, .launchAgent),
            (systemLaunchDaemons, .launchDaemon)
        ]

        var matches: [(url: URL, kind: HeadlessLoginItemKind)] = []
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
                if plistLabel.caseInsensitiveCompare(label) == .orderedSame {
                    matches.append((url, kind))
                }
            }
        }

        if matches.isEmpty { throw MutationError.notFound }
        if matches.count > 1 { throw MutationError.ambiguous(matches.map { $0.url.path }) }
        return matches[0]
    }
}
