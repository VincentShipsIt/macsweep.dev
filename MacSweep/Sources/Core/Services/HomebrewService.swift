import Foundation

@MainActor
class HomebrewService: ObservableObject {
    @Published var packages: [BrewPackage] = []
    @Published var isLoading = false
    @Published var isUpgrading = false
    @Published var upgradeLog = ""
    @Published var error: String?
    @Published var isAnalyzingAI = false

    // MARK: - Public API

    func checkOutdated() async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        guard brewExists() else {
            error = "brew_not_found"
            return
        }

        let output = shell("\(brewPath()) outdated --json=v2")
        guard let data = output.data(using: .utf8) else {
            error = "Failed to parse brew output"
            return
        }

        do {
            let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
            var result: [BrewPackage] = []

            for formula in response.formulae {
                let installed = formula.installedVersions.first ?? "unknown"
                result.append(BrewPackage(
                    id: UUID(),
                    name: formula.name,
                    currentVersion: installed,
                    latestVersion: formula.currentVersion,
                    isOutdated: true,
                    isSelected: true
                ))
            }

            for cask in response.casks {
                let installed = cask.installedVersions.first ?? "unknown"
                result.append(BrewPackage(
                    id: UUID(),
                    name: "\(cask.name) (cask)",
                    currentVersion: installed,
                    latestVersion: cask.currentVersion,
                    isOutdated: true,
                    isSelected: true
                ))
            }

            packages = result
        } catch {
            self.error = "Failed to parse brew output: \(error.localizedDescription)"
        }
    }

    func upgradeSelected() async {
        let selected = packages.filter(\.isSelected).map { $0.name.replacingOccurrences(of: " (cask)", with: "") }
        guard !selected.isEmpty else { return }
        await runUpgrade(args: selected.joined(separator: " "))
    }

    func upgradeAll() async {
        await runUpgrade(args: "")
    }

    func analyzeWithAI() async {
        guard !packages.isEmpty else { return }
        guard let apiKey = AIKeychainService.shared.loadKey(), !apiKey.isEmpty else {
            error = "No Anthropic API key configured. Add it in Settings."
            return
        }

        isAnalyzingAI = true
        defer { isAnalyzingAI = false }

        let packageList = packages.map { ["name": $0.name, "from": $0.currentVersion, "to": $0.latestVersion] }
        guard let packagesJSON = try? JSONSerialization.data(withJSONObject: packageList),
              let packagesString = String(data: packagesJSON, encoding: .utf8) else { return }

        let prompt = """
You are a macOS Homebrew expert. For each outdated package, analyze the version jump and provide:
- A 1-sentence summary of what changed
- Whether there are breaking changes (true/false)
- If breaking: what specifically breaks
- Upgrade recommendation: "Safe" or "Review first"
- Upgrade order (1=upgrade first as other packages may depend on it)

Packages: \(packagesString)
Return JSON array in same order: [{"changesSummary":"...","hasBreakingChanges":false,"breakingChangesDetail":null,"upgradeRecommendation":"Safe","upgradeOrder":1}]
Only return the JSON array, no other text.
"""

        do {
            let insights = try await callClaude(prompt: prompt, apiKey: apiKey)
            for (index, insight) in insights.enumerated() {
                if index < packages.count {
                    packages[index].aiInsight = insight
                }
            }
        } catch {
            self.error = "AI analysis failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func runUpgrade(args: String) async {
        isUpgrading = true
        upgradeLog = ""
        defer { isUpgrading = false }

        let cmd = args.isEmpty ? "\(brewPath()) upgrade" : "\(brewPath()) upgrade \(args)"
        upgradeLog = "Running: \(cmd)\n\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                Task { @MainActor [weak self] in
                    self?.upgradeLog += line
                }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
            handle.readabilityHandler = nil
            upgradeLog += "\n✅ Done (exit code: \(process.terminationStatus))"
        } catch {
            upgradeLog += "\n❌ Error: \(error.localizedDescription)"
        }

        // Refresh package list
        await checkOutdated()
    }

    private func callClaude(prompt: String, apiKey: String) async throws -> [BrewUpdateInsight] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-sonnet-4-5",
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        struct ClaudeResponse: Decodable {
            struct Content: Decodable { let text: String }
            let content: [Content]
        }

        let response = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        let text = response.content.first?.text ?? "[]"

        // Extract JSON array from response
        let jsonText: String
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") {
            jsonText = String(text[start...end])
        } else {
            jsonText = text
        }

        guard let jsonData = jsonText.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode([BrewUpdateInsight].self, from: jsonData)
    }

    func brewExists() -> Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") ||
        FileManager.default.fileExists(atPath: "/usr/local/bin/brew")
    }

    private func brewPath() -> String {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
            return "/opt/homebrew/bin/brew"
        }
        return "/usr/local/bin/brew"
    }

    private func shell(_ cmd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
