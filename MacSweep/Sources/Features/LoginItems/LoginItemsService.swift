import Foundation

/// Scans and manages macOS login items and launch agents/daemons
@MainActor
final class LoginItemsService: ObservableObject {
    static let shared = LoginItemsService()

    @Published var items: [LoginItem] = []
    @Published var isLoading = false
    @Published var isAnalyzing = false
    @Published var errorMessage: String?

    private let userLaunchAgentsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    private let systemLaunchAgentsURL = URL(fileURLWithPath: "/Library/LaunchAgents")
    private let systemLaunchDaemonsURL = URL(fileURLWithPath: "/Library/LaunchDaemons")

    private init() {}

    // MARK: - Scan

    func scan() async {
        isLoading = true
        errorMessage = nil
        var collected: [LoginItem] = []

        // 1. SMAppService items via sfltool dumpbtm
        collected += await scanSMAppServiceItems()

        // 2, 3 & 4. ~/Library/LaunchAgents, /Library/LaunchAgents, and
        // /Library/LaunchDaemons — directory enumeration + per-file plist reads
        // run off the main actor (the helpers are nonisolated statics, so no
        // main-actor hop / self capture). LaunchDaemons was previously omitted
        // here, so the GUI reported a different login-item set than the CLI
        // (LoginItemEnumerator scans it too).
        let userURL = userLaunchAgentsURL
        let sysURL = systemLaunchAgentsURL
        let daemonURL = systemLaunchDaemonsURL
        collected += await Task.detached(priority: .userInitiated) {
            Self.scanLaunchAgents(at: userURL, type: .launchAgent)
                + Self.scanLaunchAgents(at: sysURL, type: .launchAgent)
                + Self.scanLaunchAgents(at: daemonURL, type: .launchDaemon)
        }.value

        items = collected
        isLoading = false
    }

    // MARK: - SMAppService (sfltool dumpbtm)

    private func scanSMAppServiceItems() async -> [LoginItem] {
        // `sfltool dumpbtm` requires root on macOS 13+. Run without privileges it
        // produces no output and never exits — it would hang the caller. Skip it
        // unless we're root; the launch-agent/daemon scans below still enumerate
        // fine for unprivileged callers. (Matches LoginItemEnumerator.)
        guard geteuid() == 0 else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
            process.arguments = ["dumpbtm"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return []
            }

            // Drain BEFORE waiting: sfltool dumpbtm can exceed the 64 KB pipe
            // buffer, which would deadlock a wait-then-read ordering.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return await MainActor.run {
                self.parseSfltoolOutput(output)
            }
        }.value
    }

    private func parseSfltoolOutput(_ output: String) -> [LoginItem] {
        var result: [LoginItem] = []
        // sfltool dumpbtm outputs a plist-like text; extract app entries
        // Each entry has a "name" and "url" or "executableURL"
        let lines = output.components(separatedBy: "\n")
        var currentName: String?
        var currentPath: String?
        var currentBundleId: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("name = ") {
                currentName = trimmed.replacingOccurrences(of: "name = ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed.hasPrefix("url = ") || trimmed.hasPrefix("executableURL = ") {
                let raw = trimmed
                    .replacingOccurrences(of: "url = ", with: "")
                    .replacingOccurrences(of: "executableURL = ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                // Strip file:// and percent-decode (dropFirst(7) would leave
                // "%20" etc. encoded and break path lookups).
                if raw.hasPrefix("file://"), let fileURL = URL(string: raw) {
                    currentPath = fileURL.path
                } else {
                    currentPath = raw
                }
            } else if trimmed.hasPrefix("bundleIdentifier = ") {
                currentBundleId = trimmed.replacingOccurrences(of: "bundleIdentifier = ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if trimmed == "}" || trimmed == "}," {
                if let name = currentName, let path = currentPath {
                    result.append(LoginItem(
                        id: UUID(),
                        name: name,
                        path: path,
                        type: .appService,
                        bundleIdentifier: currentBundleId,
                        isEnabled: true,
                        aiAnalysis: nil
                    ))
                }
                currentName = nil
                currentPath = nil
                currentBundleId = nil
            }
        }
        return result
    }

    // MARK: - Launch Agents / Daemons

    nonisolated private static func scanLaunchAgents(at directory: URL, type: LoginItemType) -> [LoginItem] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { url in parseLaunchAgentPlist(at: url, type: type) }
    }

    nonisolated private static func parseLaunchAgentPlist(at url: URL, type: LoginItemType) -> LoginItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let label = plist["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
        let args = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? args.first ?? url.path
        let disabled = plist["Disabled"] as? Bool ?? false

        return LoginItem(
            id: UUID(),
            name: label,
            path: program,
            type: type,
            bundleIdentifier: nil,
            isEnabled: !disabled,
            aiAnalysis: nil,
            plistPath: url.path
        )
    }

    // MARK: - Enable / Disable

    @discardableResult
    func setEnabled(_ enabled: Bool, for item: LoginItem) async -> Bool {
        guard item.type != .appService else { return false } // SMAppService items managed differently

        guard let plistURL = plistURL(for: item) else {
            errorMessage = "Couldn't locate \(item.name)'s plist. Rescan login items and try again."
            return false
        }

        // Read/patch/write off the main actor so a slow disk doesn't freeze the UI,
        // and PRESERVE the on-disk plist format — a binary plist must stay binary,
        // not be silently rewritten as XML.
        do {
            try await Task.detached(priority: .userInitiated) {
                var fmt = PropertyListSerialization.PropertyListFormat.xml
                let data = try Data(contentsOf: plistURL)
                guard var plist = try PropertyListSerialization.propertyList(from: data, format: &fmt) as? [String: Any] else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
                plist["Disabled"] = !enabled
                let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: fmt, options: 0)
                try newData.write(to: plistURL)
            }.value
        } catch {
            errorMessage = "Couldn't update \(item.name): \(error.localizedDescription)"
            return false
        }

        // Back on the main actor after the await — safe to mutate @Published state.
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isEnabled = enabled
        }
        return true
    }

    // MARK: - Delete

    func delete(_ item: LoginItem) async {
        guard item.type != .appService else { return }

        guard let url = plistURL(for: item) else {
            errorMessage = "Couldn't locate \(item.name)'s plist. Rescan login items and try again."
            return
        }
        do {
            // Move to Trash (recoverable) rather than a hard delete, matching
            // LoginItemController.remove and the rest of the cleanup modules.
            // Off the main actor so trashItem doesn't stall the UI.
            try await Task.detached(priority: .userInitiated) {
                try CleanupFileRemover.recoverable(url, module: "login-items")
            }.value
        } catch {
            errorMessage = "Couldn't remove \(item.name): \(error.localizedDescription)"
            return
        }
        items.removeAll { $0.id == item.id }
    }

    private func plistURL(for item: LoginItem) -> URL? {
        // Prefer the EXACT path captured at scan time. A launch agent's plist
        // filename routinely differs from its Label, so guessing "<Label>.plist"
        // can resolve to a DIFFERENT agent that merely happens to be named after
        // this one's Label — and then mutate/trash the wrong file.
        if let stored = item.plistPath {
            let url = URL(fileURLWithPath: stored)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        // Fallback only for items with no stored path (e.g. legacy deserialized state).
        let fileName = item.name + ".plist"
        let userURL = userLaunchAgentsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: userURL.path) {
            return userURL
        }
        let sysURL = systemLaunchAgentsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: sysURL.path) {
            return sysURL
        }
        return nil
    }

    // MARK: - AI Analysis

    func analyzeWithAI() async {
        guard !items.isEmpty else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }

        guard let apiKey = loadAPIKey() else {
            errorMessage = "No API key found. Add your Anthropic key in Settings."
            return
        }

        let itemsPayload = items.map { item in
            ["name": item.name, "path": item.path, "bundleId": item.bundleIdentifier ?? ""]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: itemsPayload),
              let jsonString = String(data: jsonData, encoding: .utf8)
        else { return }

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-opus-4-5",
            "max_tokens": 4096,
            "system": "You are a macOS security expert analyzing startup items. Be concise and accurate.",
            "messages": [
                [
                    "role": "user",
                    "content": """
                    Analyze these login items and launch agents. For each, provide: a plain English explanation of what it does, risk level (safe/suspicious/unknown), and recommendation.
                    Items: \(jsonString)
                    Return a JSON array matching input order (same count): [{"summary":"...","riskLevel":"safe|suspicious|unknown","recommendation":"..."}]
                    Return ONLY the JSON array, no other text.
                    """
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = bodyData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = response["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String
            else { return }

            // Parse the JSON array from Claude's response
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let analysisData = cleaned.data(using: .utf8),
                  let analyses = try? JSONDecoder().decode([AIItemAnalysisResponse].self, from: analysisData)
            else { return }

            for (idx, analysis) in analyses.enumerated() where idx < items.count {
                items[idx].aiAnalysis = AIItemAnalysis(
                    summary: analysis.summary,
                    riskLevel: RiskLevel(rawValue: analysis.riskLevel) ?? .unknown,
                    recommendation: analysis.recommendation,
                    lastSeenDaysAgo: nil
                )
            }
        } catch {
            errorMessage = "AI analysis failed: \(error.localizedDescription)"
        }
    }

    private func loadAPIKey() -> String? {
        // Use the shared keychain service so the key saved in the AI Analysis
        // settings popover is found here too. Previously this read a separate
        // service string ("com.macsweep.anthropic-api-key"), so a normally
        // saved key was never found and analysis silently fell back to the env.
        if let key = AIKeychainService.shared.loadKey() {
            return key
        }
        // Fallback: environment variable (dev mode)
        return ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }
}

// MARK: - Decoding helper

private struct AIItemAnalysisResponse: Decodable {
    let summary: String
    let riskLevel: String
    let recommendation: String
}
