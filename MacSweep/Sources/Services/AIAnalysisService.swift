import Foundation

@MainActor
class AIAnalysisService: ObservableObject {
    @Published var findings: [CacheFinding] = []
    @Published var isScanning = false
    @Published var phase = ""
    @Published var error: String?

    func scan() async {
        isScanning = true
        findings = []
        error = nil

        phase = "Scanning caches..."
        let result = await CacheAnalyzer().analyze(deep: true)
        findings = result.findings.map { finding in
            CacheFinding(
                path: finding.path,
                size: finding.sizeText,
                category: CacheCategory(rawValue: finding.category.rawValue) ?? .other,
                regeneratesAutomatically: finding.regeneratesAutomatically,
                source: finding.source == "Fast Scan" ? .deterministic : .ai,
                reason: finding.reason
            )
        }
        error = result.errors.isEmpty ? nil : result.errors.joined(separator: "; ")
        phase = result.aiRan ? "Done" : "Fast scan results only"
        isScanning = false
    }

    // MARK: - Fast Scan

    private func runFastScan() async -> [CacheFinding] {
        let script = #"""
        find ~ \( \
          -path "*/Library/Application Support/*/Code Cache" \
          -o -path "*/Library/Application Support/*/GPUCache" \
          -o -path "*/Library/Application Support/*/DawnWebGPUCache" \
          -o -path "*/Library/Application Support/*/DawnGraphiteCache" \
          -o -path "*/Library/Application Support/*/ShaderCache" \
          -o -path "*/vm_bundles/warm" \
          -o -path "*/.npm/_cacache" \
          -o -path "*/.npm/_npx" \
          -o -path "*/.npm/_logs" \
          -o -path "*/.bun/install/cache" \
          -o -path "*/.yarn/cache" \
          -o -path "*/.pnpm-store" \
          -o -path "*/.cache/pip" \
          -o -path "*/.cache/uv" \
          -o -path "*/.claude/debug" \
          -o -path "*/.claude/paste-cache" \
          -o -path "*/.claude/telemetry" \
          -o -path "*/.claude/shell-snapshots" \
          -o -path "*/.codex/log" \
          -o -path "*/.codex/archived_sessions" \
        \) -maxdepth 8 -type d -prune 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh
        """#
        return await Task.detached(priority: .userInitiated) {
            let result = self.shell(script)
            return self.parseFastScanOutput(result)
        }.value
    }

    // Pure transform — touches no actor-isolated state, so it runs off the main
    // actor inside the detached fast-scan task.
    private nonisolated func parseFastScanOutput(_ output: String) -> [CacheFinding] {
        output.components(separatedBy: "\n").compactMap { line -> CacheFinding? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { return nil }
            let size = parts[0].trimmingCharacters(in: .whitespaces)
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return CacheFinding(
                path: path,
                size: size,
                category: categorize(path: path),
                regeneratesAutomatically: true,
                source: .deterministic
            )
        }
    }

    private nonisolated func categorize(path: String) -> CacheCategory {
        let p = path.lowercased()
        if p.contains("code cache") || p.contains("gpucache") || p.contains("dawn") ||
           p.contains("shadercache") || p.contains("vm_bundles/warm") {
            return .electronChromium
        }
        if p.contains(".npm") || p.contains(".bun") || p.contains(".yarn") ||
           p.contains(".pnpm") || p.contains(".cache/pip") || p.contains(".cache/uv") {
            return .packageManager
        }
        if p.contains(".claude") || p.contains(".codex") {
            return .aiToolCache
        }
        if p.contains("debug") || p.contains("/log") || p.contains("archived_sessions") {
            return .devDebugLogs
        }
        return .other
    }

    // MARK: - AI Scan

    private func runAIScan(apiKey: String) async -> [CacheFinding] {
        let dirList = await Task.detached(priority: .userInitiated) {
            self.shell(#"du -sh ~/Library/Application\ Support/*/ 2>/dev/null | sort -rh | head -50"#)
        }.value

        let prompt = """
        You are a disk cleanup scanner for macOS developer machines.

        Here are the largest directories in ~/Library/Application Support:
        \(dirList)

        Identify safe-to-delete cache directories. Categories:
        1. Electron/Chromium: "Code Cache", "GPUCache", "DawnWebGPUCache", "DawnGraphiteCache", "ShaderCache", "warm" in "vm_bundles/"
        2. Package Manager: .npm/_cacache, .npm/_npx, .bun/install/cache, .yarn/cache, .pnpm-store, .cache/pip, .cache/uv
        3. Dev Debug Logs: dotdir's "debug", "log", "logs", "archived_sessions"
        4. AI Tool Caches: .claude/debug, .claude/paste-cache, .claude/telemetry, .claude/shell-snapshots

        NEVER flag: /projects/, /sessions/, /global/, *.json, *.bundle, vm_bundles/claudevm.bundle, ~/.bun/install/global

        Respond ONLY with a JSON array (no markdown):
        [{"path":"...","size_estimate":"...","category":"Electron/Chromium|Package Manager|Dev Debug Logs|AI Tool Cache|Other","regenerates_automatically":true,"reason":"..."}]
        """

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        request.httpBody = httpBody

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = (json["content"] as? [[String: Any]])?.first,
               let text = content["text"] as? String,
               let arrayData = text.data(using: .utf8),
               let items = try? JSONDecoder().decode([[String: AnyCodable]].self, from: arrayData) {
                return items.compactMap { item -> CacheFinding? in
                    guard let path = item["path"]?.value as? String else { return nil }
                    let size = item["size_estimate"]?.value as? String ?? "Unknown"
                    let cat = item["category"]?.value as? String ?? "Other"
                    let regen = item["regenerates_automatically"]?.value as? Bool ?? true
                    let reason = item["reason"]?.value as? String
                    return CacheFinding(
                        path: path,
                        size: size,
                        category: CacheCategory(rawValue: cat) ?? .other,
                        regeneratesAutomatically: regen,
                        source: .ai,
                        reason: reason
                    )
                }
            }
        } catch {
            self.error = "AI scan failed: \(error.localizedDescription)"
        }
        return []
    }

    // MARK: - Shell helper

    private nonisolated func shell(_ cmd: String) -> String {
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", cmd]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - AnyCodable helper for mixed JSON

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = value as? Bool { try c.encode(v) }
        else if let v = value as? Int { try c.encode(v) }
        else if let v = value as? Double { try c.encode(v) }
        else if let v = value as? String { try c.encode(v) }
    }
}
