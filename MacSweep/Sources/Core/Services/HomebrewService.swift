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

        // Resolve REAL dependency edges among the outdated set so the model orders
        // upgrades from actual `brew deps`, not a guess. Casks have no `brew deps`
        // graph, so the cask suffix is stripped before querying.
        let cleanNames = packages.map { $0.name.replacingOccurrences(of: " (cask)", with: "") }
        let outdatedSet = Set(cleanNames)
        var depsByName: [String: [String]] = [:]
        for name in cleanNames {
            let raw = shell("\(brewPath()) deps \(name) 2>/dev/null")
            let deps = raw.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Only edges WITHIN the outdated set matter for ordering this batch.
            depsByName[name] = deps.filter { outdatedSet.contains($0) }
        }

        let packageList: [[String: Any]] = packages.map { pkg in
            let clean = pkg.name.replacingOccurrences(of: " (cask)", with: "")
            return [
                "name": pkg.name,
                "from": pkg.currentVersion,
                "to": pkg.latestVersion,
                "dependsOn": depsByName[clean] ?? []
            ]
        }
        guard let packagesJSON = try? JSONSerialization.data(withJSONObject: packageList),
              let packagesString = String(data: packagesJSON, encoding: .utf8) else { return }

        let prompt = """
You are a macOS Homebrew expert. For each outdated package, analyze the version jump and provide:
- A 1-sentence summary of what changed
- Whether there are breaking changes (true/false)
- If breaking: what specifically breaks
- Upgrade recommendation: "Safe" or "Review first"
- Upgrade order (1=upgrade first). Derive the order STRICTLY from the `dependsOn` field:
  a package must be upgraded AFTER every package listed in its `dependsOn`. Packages
  with an empty `dependsOn` can go first. Do NOT guess dependencies — use only `dependsOn`.

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

    /// Reclaim disk by removing stale downloads and old installed versions
    /// (`brew cleanup -s`). Returns the full log plus the reclaimed-space line Brew
    /// prints, when present. Read-mostly: brew only deletes its own cached artifacts.
    func cleanup() async -> (success: Bool, reclaimedText: String?, log: String) {
        guard brewExists() else { return (false, nil, "brew_not_found") }
        let output = shell("\(brewPath()) cleanup -s 2>&1")
        // Brew emits e.g. "==> This operation has freed approximately 1.2GB of disk space."
        let reclaimed = output
            .components(separatedBy: .newlines)
            .first { $0.lowercased().contains("freed approximately") }?
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "==> ", with: "")
        return (true, reclaimed, output)
    }

    /// Top-level formulae — installed packages that are NOT a dependency of any other
    /// installed formula (`brew leaves`). These are the packages the user explicitly
    /// wanted; everything else is a pulled-in dependency.
    func leaves() async -> [String] {
        guard brewExists() else { return [] }
        let output = shell("\(brewPath()) leaves 2>/dev/null")
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Homebrew command that upgrades MacSweep itself via its tap. Printed by the
    /// CLI's `self-update` (no `--yes`) so the user can run it manually, and executed
    /// directly by `selfUpgrade()`.
    static let selfUpgradeCommand = "brew upgrade vincentshipsit/macsweep/macsweep"

    /// Upgrade the installed `macsweep` formula in place. Caller is responsible for
    /// checking `brewExists()` first; this guards too and returns a sentinel log so
    /// the headless layer can map the absence to the right exit code.
    func selfUpgrade() async -> (success: Bool, log: String) {
        guard brewExists() else { return (false, "brew_not_found") }
        let output = shell("\(brewPath()) upgrade vincentshipsit/macsweep/macsweep 2>&1")
        return (true, output)
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
