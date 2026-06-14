import Foundation

/// Deterministic + optional AI-assisted developer-cache scanner.
///
/// Ported from the GUI-only `AIAnalysisService` into Core so the headless/CLI
/// layer can drive the same logic. The fast scan is pure deterministic shell
/// discovery and always runs; the AI scan is gated on an Anthropic key stored in
/// the Keychain and only runs when `deep` is requested. No state is mutated and
/// nothing is deleted — this is read-only reconnaissance.
struct CacheAnalyzer {

    /// Mirrors the GUI `CacheCategory` raw values so JSON output is identical
    /// across the app and CLI.
    enum Category: String {
        case electronChromium = "Electron/Chromium"
        case packageManager = "Package Manager"
        case devDebugLogs = "Dev Debug Logs"
        case aiToolCache = "AI Tool Cache"
        case other = "Other"
    }

    struct Finding {
        let path: String
        let sizeText: String
        let category: Category
        let regeneratesAutomatically: Bool
        let source: String   // "Fast Scan" | "AI Analysis"
        let reason: String?
    }

    struct Result {
        let findings: [Finding]
        let fastCount: Int
        let aiRan: Bool
        let errors: [String]
    }

    /// Run the deterministic fast scan (always) plus, when `deep` is true and an
    /// Anthropic key is present in the Keychain, an AI semantic scan. AI results
    /// are deduplicated against fast-scan paths. Errors are collected rather than
    /// thrown so a failed AI call still returns the deterministic findings.
    func analyze(deep: Bool) async -> Result {
        var errors: [String] = []
        let fast = await runFastScan()
        var findings = fast
        var aiRan = false

        if deep {
            if let key = AIKeychainService.shared.loadKey() {
                let (aiFindings, aiError) = await runAIScan(apiKey: key)
                let existing = Set(findings.map { $0.path })
                findings.append(contentsOf: aiFindings.filter { !existing.contains($0.path) })
                aiRan = true
                if let aiError { errors.append(aiError) }
            } else {
                errors.append("AI scan requested but no Anthropic API key is stored. Add one in the MacSweep app.")
            }
        }

        return Result(findings: findings, fastCount: fast.count, aiRan: aiRan, errors: errors)
    }

    // MARK: - Fast Scan

    private func runFastScan() async -> [Finding] {
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
          -o -path "*/.cargo/registry" \
          -o -path "*/.cargo/git" \
          -o -path "*/go/pkg/mod" \
          -o -path "*/.cache/go-build" \
          -o -path "*/.gradle/caches" \
          -o -path "*/.m2/repository" \
          -o -path "*/.claude/debug" \
          -o -path "*/.claude/paste-cache" \
          -o -path "*/.claude/telemetry" \
          -o -path "*/.claude/shell-snapshots" \
          -o -path "*/.codex/log" \
          -o -path "*/.codex/archived_sessions" \
        \) -maxdepth 8 -type d -prune 2>/dev/null | xargs du -sh 2>/dev/null | sort -rh
        """#
        return await Task.detached(priority: .userInitiated) {
            let result = Self.shell(script)
            return Self.parseFastScanOutput(result)
        }.value
    }

    /// Pure transform of `du -sh` tab-separated output into findings.
    private static func parseFastScanOutput(_ output: String) -> [Finding] {
        output.components(separatedBy: "\n").compactMap { line -> Finding? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 2 else { return nil }
            let size = parts[0].trimmingCharacters(in: .whitespaces)
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return Finding(
                path: path,
                sizeText: size,
                category: categorize(path: path),
                regeneratesAutomatically: true,
                source: "Fast Scan",
                reason: nil
            )
        }
    }

    private static func categorize(path: String) -> Category {
        let p = path.lowercased()
        if p.contains("code cache") || p.contains("gpucache") || p.contains("dawn") ||
           p.contains("shadercache") || p.contains("vm_bundles/warm") {
            return .electronChromium
        }
        if p.contains(".npm") || p.contains(".bun") || p.contains(".yarn") ||
           p.contains(".pnpm") || p.contains(".cache/pip") || p.contains(".cache/uv") ||
           p.contains(".cargo") || p.contains("/go/pkg/mod") || p.contains("go-build") ||
           p.contains(".gradle/caches") || p.contains(".m2/repository") {
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

    /// POST the largest `~/Library/Application Support` directories to the
    /// Anthropic Messages API and parse the JSON array of suggested cache dirs.
    /// Returns `(findings, error?)` — errors are surfaced, never thrown.
    private func runAIScan(apiKey: String) async -> ([Finding], String?) {
        let dirList = await Task.detached(priority: .userInitiated) {
            Self.shell(#"du -sh ~/Library/Application\ Support/*/ 2>/dev/null | sort -rh | head -50"#)
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

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return ([], "AI scan failed: invalid endpoint URL.")
        }
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

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            return ([], "AI scan failed: could not encode request body.")
        }
        request.httpBody = httpBody

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = (json["content"] as? [[String: Any]])?.first,
                  let text = content["text"] as? String,
                  let arrayData = text.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: arrayData) as? [[String: Any]] else {
                return ([], "AI scan returned an unparseable response.")
            }
            let findings = items.compactMap { item -> Finding? in
                guard let path = item["path"] as? String else { return nil }
                let size = item["size_estimate"] as? String ?? "Unknown"
                let cat = item["category"] as? String ?? "Other"
                let regen = item["regenerates_automatically"] as? Bool ?? true
                let reason = item["reason"] as? String
                return Finding(
                    path: path,
                    sizeText: size,
                    category: Category(rawValue: cat) ?? .other,
                    regeneratesAutomatically: regen,
                    source: "AI Analysis",
                    reason: reason
                )
            }
            return (findings, nil)
        } catch {
            return ([], "AI scan failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Shell helper

    private static func shell(_ cmd: String) -> String {
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
