import Darwin
import Foundation

enum UpdateProtection {
    struct Scope: Sendable {
        var roots: [URL] = []
        var reason: String?
    }

    static func identity(_ path: URL) throws -> (DevArtifactIdentity, DevArtifactNode) {
        let resolved = path.resolvingSymlinksInPath()
        let identity = try DevArtifactIdentity.read(resolved)
        var info = stat()
        guard lstat(resolved.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw DevArtifactSafetyError("The native package-manager executable is unavailable.")
        }
        return (identity, .init(path: resolved.path, status: info))
    }

    static func writableReason(_ roots: [URL]) -> String? {
        guard !roots.isEmpty else { return "Install location is unknown; check this source manually." }
        for root in roots {
            var info = stat()
            guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                root.standardizedFileURL.path == root.resolvingSymlinksInPath().path,
                FileManager.default.isWritableFile(atPath: root.path)
            else {
                return
                    "The install location is unavailable, redirected or not writable without elevation. "
                    + "Update this item manually."
            }
        }
        return nil
    }

    static func absolutePath(_ result: ProcessResult) throws -> URL {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.didSucceed, result.outputWasValidUTF8, text.hasPrefix("/"), text.utf8.count < 4096,
            !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw DevArtifactSafetyError("The manager did not provide a supported absolute install location.")
        }
        return URL(fileURLWithPath: text).standardizedFileURL
    }

    static func caskRequiresAdministrator(_ text: String) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            let casks = object["casks"] as? [[String: Any]], casks.count == 1,
            let artifacts = casks[0]["artifacts"] as? [[String: Any]]
        else { throw UpdateParsers.unsupported() }
        return artifacts.contains { artifact in
            !Set(artifact.keys).isDisjoint(with: [
                "pkg", "installer", "preflight", "postflight", "uninstall_preflight", "uninstall_postflight"
            ])
        }
    }

    static func hasHomebrewNoSudo(manager: URL) -> Bool {
        let prefix = manager.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let file = prefix.appendingPathComponent("Library/Homebrew/env_config.rb")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            let size = attributes[.size] as? NSNumber, size.int64Value < 2_097_152,
            let source = try? String(contentsOf: file, encoding: .utf8)
        else { return false }
        return source.contains("HOMEBREW_NO_SUDO:")
    }
}
