import AppKit
import Darwin
import Foundation

/// Installed and running applications are retention evidence, never deletion authority.
enum AppOwnershipDiscovery {
    static func inventory() async -> AppOwnershipInventory {
        var result = AppOwnershipInventory()
        result.running = await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications"),
            URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices")
        ]
        for root in roots {
            var metadata = stat()
            if lstat(root.path, &metadata) != 0, errno == ENOENT { continue }
            do {
                let apps = try applicationInventory(in: root)
                result.installed.formUnion(apps.installed)
                result.installedNames.formUnion(apps.installedNames)
            } catch {
                result.issues.append(
                    "Installed application inventory incomplete: \(root.lastPathComponent). "
                        + error.localizedDescription
                )
            }
        }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        if let brew {
            do {
                let response = try await ProcessRunner.run(
                    executable: brew,
                    arguments: ["info", "--json=v2", "--cask", "--installed"], timeout: 30)
                guard response.didSucceed else { throw DevArtifactSafetyError("Cask inventory unavailable.") }
                let casks = try caskOwnership(response.output, applicationRoots: Array(roots.prefix(2)))
                result.installed.formUnion(casks.installed)
                result.issues.append(contentsOf: casks.issues)
            } catch { result.issues.append("Homebrew cask inventory incomplete; all findings retained.") }
        } else if ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"].contains(where: {
            FileManager.default.fileExists(atPath: $0)
        }) {
            result.issues.append("Caskroom exists but Homebrew is unavailable.")
        }
        return result
    }

    static func caskOwnership(_ output: String, applicationRoots: [URL]) throws -> AppOwnershipInventory {
        guard let data = output.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let casks = json["casks"] as? [[String: Any]]
        else {
            throw DevArtifactSafetyError("Cask inventory unavailable.")
        }
        var result = AppOwnershipInventory()
        for cask in casks {
            guard let artifacts = cask["artifacts"] as? [[String: Any]] else {
                result.issues.append("Cask artifact inventory unavailable.")
                continue
            }
            for artifact in artifacts {
                guard let value = artifact["app"] else { continue }
                guard let apps = value as? [Any], apps.first is String else {
                    result.issues.append("Cask application artifact format unavailable.")
                    continue
                }
                for name in apps.compactMap({ $0 as? String }) {
                    let ids = applicationRoots.compactMap { root in
                        Bundle(url: root.appending(path: name))?.bundleIdentifier
                    }
                    if ids.isEmpty { result.issues.append("Installed cask application ownership unresolved.") }
                    result.installed.formUnion(ids)
                }
            }
        }
        return result
    }

    static func hasRegisteredOwner(_ identifier: String) -> Bool {
        guard let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return false }
        var metadata = stat()
        if lstat(path.path, &metadata) == 0 { return true }
        // An inaccessible registered installation cannot prove owner absence.
        return errno != ENOENT
    }

    static func bundleIdentifiers(in root: URL) throws -> Set<String> {
        try applicationInventory(in: root).installed
    }

    private static func applicationInventory(in root: URL) throws -> AppOwnershipInventory {
        _ = try ManagedCleanupEvidence.identity(root)
        var result = AppOwnershipInventory()
        var failure: Error?
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        guard
            let entries = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                errorHandler: { _, error in
                    failure = error
                    return false
                })
        else { throw DevArtifactSafetyError("Application directory unavailable.") }
        var count = 0
        for case let path as URL in entries {
            count += 1
            guard count <= 30_000, ProcessInfo.processInfo.systemUptime < deadline else {
                throw DevArtifactSafetyError("Application inventory exceeded its limit.")
            }
            if path.pathExtension == "app" {
                guard let identifier = Bundle(url: path)?.bundleIdentifier else {
                    throw DevArtifactSafetyError("Application identifier unavailable.")
                }
                result.installed.insert(identifier)
                let bundle = Bundle(url: path)
                let names = [
                    path.deletingPathExtension().lastPathComponent,
                    bundle?.infoDictionary?["CFBundleName"] as? String,
                    bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                ]
                result.installedNames.formUnion(names.compactMap { $0?.lowercased() })
                entries.skipDescendants()
            } else if try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                // Unknown linked installation roots cannot establish app absence.
                throw DevArtifactSafetyError("Linked application directory requires review.")
            }
        }
        if let failure { throw failure }
        return result
    }
}
