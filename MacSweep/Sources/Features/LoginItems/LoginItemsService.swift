import Foundation
import Security

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

    private init() {}

    // MARK: - Scan

    func scan() async {
        isLoading = true
        errorMessage = nil
        var collected: [LoginItem] = []

        // 1. SMAppService items via sfltool dumpbtm
        collected += await scanSMAppServiceItems()

        // 2. ~/Library/LaunchAgents
        collected += scanLaunchAgents(at: userLaunchAgentsURL, type: .launchAgent)

        // 3. /Library/LaunchAgents
        collected += scanLaunchAgents(at: systemLaunchAgentsURL, type: .launchAgent)

        items = collected
        isLoading = false
    }

    // MARK: - SMAppService (sfltool dumpbtm)

    private func scanSMAppServiceItems() async -> [LoginItem] {
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
            process.arguments = ["dumpbtm"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return []
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
                // Strip file:// prefix
                currentPath = raw.hasPrefix("file://") ? String(raw.dropFirst(7)) : raw
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

    private func scanLaunchAgents(at directory: URL, type: LoginItemType) -> [LoginItem] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "plist" }
            .compactMap { url in parseLaunchAgentPlist(at: url, type: type) }
    }

    private func parseLaunchAgentPlist(at url: URL, type: LoginItemType) -> LoginItem? {
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
            aiAnalysis: nil
        )
    }

    // MARK: - Enable / Disable

    func setEnabled(_ enabled: Bool, for item: LoginItem) async {
        guard item.type != .appService else { return } // SMAppService items managed differently

        let plistURL = plistURL(for: item)
        guard let plistURL else { return }

        guard let data = try? Data(contentsOf: plistURL),
              var plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }

        plist["Disabled"] = !enabled

        if let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? newData.write(to: plistURL)
        }

        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isEnabled = enabled
        }
    }

    // MARK: - Delete

    func delete(_ item: LoginItem) async {
        guard item.type != .appService else { return }

        let plistURL = plistURL(for: item)
        if let url = plistURL {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
    }

    private func plistURL(for item: LoginItem) -> URL? {
        // Check user agents first, then system agents
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
        // Try keychain first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.macsweep.anthropic-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8) {
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
