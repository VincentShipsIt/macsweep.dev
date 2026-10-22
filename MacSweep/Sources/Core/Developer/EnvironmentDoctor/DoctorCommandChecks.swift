import Darwin
import Foundation

enum DoctorCommandChecks {
    static func loginPath(paths: DoctorPaths, command: DoctorCommandRunner) async -> DoctorInventory {
        let supported = ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
        guard supported.contains(paths.shell) else {
            return DoctorInventory(issues: ["Login shell is unsupported for effective PATH inspection: \(paths.shell)"])
        }
        let marker = "__MACSWEEP_PATH_\(UUID().uuidString)__"
        let expression = paths.shell.hasSuffix("/fish") ? "string join ':' $PATH" : "printf '%s' \"$PATH\""
        let script = "printf '\\n%s\\n' '\(marker)'; \(expression); printf '\\n%s\\n' '\(marker)'"
        do {
            let result = try await command(paths.shell, ["-l", "-i", "-c", script], 10)
            try result.checkedSuccess()
            guard result.outputWasValidUTF8, result.output.utf8.count <= 1_048_576 else {
                throw DevArtifactSafetyError("Effective PATH output is incomplete or oversized.")
            }
            let pieces = result.output.components(separatedBy: marker)
            guard pieces.count == 3 else { throw DevArtifactSafetyError("Effective PATH markers were not returned.") }
            let value = pieces[1].trimmingCharacters(in: .newlines)
            return inspectPath(value, sources: sourceHints(paths.home))
        } catch { return DoctorInventory(issues: ["Login PATH inspection failed: \(error.localizedDescription)"]) }
    }

    static func inspectPath(_ value: String, sources: [(URL, String)] = []) -> DoctorInventory {
        var result = DoctorInventory()
        guard value.utf8.count <= 65_536 else { return DoctorInventory(issues: ["PATH is oversized."]) }
        var seen = Set<String>()
        for entry in value.components(separatedBy: ":") {
            guard entry.hasPrefix("/") else {
                result.findings.append(
                    pathFinding(
                        entry, reason: "Relative or empty PATH entry uses the current directory.",
                        sources: sources))
                continue
            }
            var status = stat()
            var reason: String?
            var identity = URL(fileURLWithPath: entry).standardizedFileURL.path
            if fstatat(AT_FDCWD, entry, &status, 0) == 0 {
                if status.st_mode & S_IFMT != S_IFDIR { reason = "PATH entry is not a directory." }
                identity = "\(status.st_dev):\(status.st_ino)"
            } else if errno == ENOENT || errno == ENOTDIR {
                reason = "PATH directory does not exist."
            } else {
                result.issues.append("PATH entry existence could not be verified: \(entry)")
                continue
            }
            if !seen.insert(identity).inserted { reason = "Duplicate PATH directory." }
            if let reason { result.findings.append(pathFinding(entry, reason: reason, sources: sources)) }
        }
        return result
    }

    private static func pathFinding(_ entry: String, reason: String, sources: [(URL, String)]) -> DoctorFinding {
        let hints =
            entry.isEmpty
            ? []
            : sources.flatMap { file, text in
                text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                    line.contains(entry) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                        ? "\(file.path):\(index + 1)" : nil
                }
            }
        let hint =
            hints.isEmpty ? " Source could not be determined." : " Possible source: " + hints.joined(separator: ", ")
        return DoctorFinding(
            category: .path, path: nil,
            evidence: "\(reason) Entry: \(entry.isEmpty ? "(empty)" : entry)." + hint,
            remediation: "Review the indicated shell configuration and remove or correct this PATH entry manually. "
                + "MacSweep never edits shell configuration.", requiresAdministrator: false, repair: nil, stamp: nil)
    }

    private static func sourceHints(_ home: URL) -> [(URL, String)] {
        let names = [
            ".zprofile", ".zshrc", ".zshenv", ".bash_profile", ".bashrc", ".profile", ".config/fish/config.fish"
        ]
        var files = names.map { home.appendingPathComponent($0) }
        files += [URL(fileURLWithPath: "/etc/paths"), URL(fileURLWithPath: "/etc/zprofile")]
        files +=
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: "/etc/paths.d"),
                includingPropertiesForKeys: nil)) ?? []
        return files.prefix(64).compactMap { path in
            var status = stat()
            guard lstat(path.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                status.st_size <= 65_536,
                let data = try? AuthorizedFileEvidence.read(
                    path, maximumBytes: 65_536, expected: DevArtifactNode(path: path.path, status: status)),
                let text = String(data: data, encoding: .utf8)
            else { return nil }
            return (path, text)
        }
    }

    static func homebrew(paths: DoctorPaths, command: DoctorCommandRunner) async -> DoctorInventory {
        guard let brew = paths.brew else { return DoctorInventory() }
        do {
            let output = try await command(
                "/usr/bin/env",
                [
                    "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1",
                    "NONINTERACTIVE=1", brew, "doctor"
                ], 30)
            guard output.outputWasValidUTF8, output.output.utf8.count + output.error.utf8.count <= 1_048_576 else {
                throw DevArtifactSafetyError("Homebrew doctor output is incomplete or oversized.")
            }
            return parseHomebrew(output)
        } catch { return DoctorInventory(issues: ["Homebrew doctor failed: \(error.localizedDescription)"]) }
    }

    static func parseHomebrew(_ result: ProcessResult) -> DoctorInventory {
        let text = (result.output + "\n" + result.error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return result.didSucceed
                ? DoctorInventory() : DoctorInventory(issues: ["Homebrew doctor failed without output."])
        }
        guard !result.didSucceed || text.contains("Warning:") || text.contains("Error:") else {
            return DoctorInventory()
        }
        return DoctorInventory(findings: [
            DoctorFinding(
                category: .homebrew, path: nil,
                evidence: text,
                remediation: "Review brew doctor in Terminal and follow its specific instructions. "
                    + "MacSweep does not apply Homebrew doctor suggestions automatically.",
                requiresAdministrator: false, repair: nil, stamp: nil)
        ])
    }
}
