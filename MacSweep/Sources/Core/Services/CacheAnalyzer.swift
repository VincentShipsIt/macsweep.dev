import Foundation

/// Deterministic + optional AI-assisted developer-cache scanner.
///
/// Ported from the GUI-only `AIAnalysisService` into Core so the headless/CLI
/// layer can drive the same logic. The fast scan is pure deterministic shell
/// discovery and always runs; the AI scan prefers local assistant CLIs
/// (`claude -p`, then `codex exec`) and falls back to an Anthropic key stored in
/// the Keychain only when no local provider succeeds. No state is mutated and
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

    /// Run the deterministic fast scan (always) plus, when `deep` is true, an AI
    /// semantic scan using local CLIs before falling back to the stored API key.
    /// AI results are deduplicated against fast-scan paths. Errors are collected
    /// rather than thrown so a failed AI call still returns deterministic findings.
    func analyze(deep: Bool) async -> Result {
        var errors: [String] = []
        let fast = await runFastScan()
        var findings = fast
        var aiRan = false

        if deep {
            let dirList = await largestApplicationSupportDirectories()
            let prompt = makeAIPrompt(dirList: dirList)
            let local = await runLocalAIScan(prompt: prompt)

            if local.provider != nil {
                let existing = Set(findings.map { $0.path })
                findings.append(contentsOf: local.findings.filter { !existing.contains($0.path) })
                aiRan = true
                if let error = local.error { errors.append(error) }
            } else if let key = AIKeychainService.shared.loadKey() {
                let anthropic = await runAnthropicScan(apiKey: key, prompt: prompt)
                let existing = Set(findings.map { $0.path })
                findings.append(contentsOf: anthropic.findings.filter { !existing.contains($0.path) })
                aiRan = true
                if let error = anthropic.error { errors.append(error) }
            } else {
                if let error = local.error {
                    errors.append(error)
                }
                errors.append("AI scan requested but no Claude/Codex CLI or Anthropic API key is available.")
            }
        }

        return Result(findings: findings, fastCount: fast.count, aiRan: aiRan, errors: errors)
    }

    // MARK: - Fast Scan

    private func runFastScan() async -> [Finding] {
        let script = #"""
        find ~ -maxdepth 8 \( \
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
        \) -type d -prune -print0 2>/dev/null | xargs -0 du -sh 2>/dev/null | sort -rh
        """#
        return await Task.detached(priority: .userInitiated) {
            let result = Self.shell(script)
            return Self.parseFastScanOutput(result)
        }.value
    }

    /// Pure transform of `du -sh` tab-separated output into findings.
    /// `internal` (not `private`) so the deterministic parse/categorize logic is
    /// reachable from `@testable import` unit tests.
    static func parseFastScanOutput(_ output: String) -> [Finding] {
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

    static func categorize(path: String) -> Category {
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

    private func largestApplicationSupportDirectories() async -> String {
        await Task.detached(priority: .userInitiated) {
            Self.shell(#"du -sh ~/Library/Application\ Support/*/ 2>/dev/null | sort -rh | head -50"#)
        }.value
    }

    private func makeAIPrompt(dirList: String) -> String {
        """
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
    }

    private func runLocalAIScan(prompt: String) async -> (findings: [Finding], provider: String?, error: String?) {
        var errors: [String] = []

        if Self.executablePath(for: "claude") != nil {
            // Run off the cooperative pool — the CLI can take many seconds and
            // runProcess blocks on waitUntilExit (matches runFastScan's pattern).
            let result = await Task.detached(priority: .userInitiated) {
                Self.runProcess([
                    "claude",
                    "-p",
                    "--json-schema", Self.aiSchemaString,
                    prompt
                ])
            }.value
            if result.status == 0 {
                if let findings = Self.parseAIFindings(result.output, source: "AI Analysis") {
                    return (findings, "Claude CLI", nil)
                }
                errors.append("Claude CLI returned an unparseable AI scan response.")
            } else {
                errors.append(Self.processError("Claude CLI", result))
            }
        }

        if Self.executablePath(for: "codex") != nil {
            let schemaURL = FileManager.default.temporaryDirectory.appending(path: "macsweep-cache-schema-\(UUID().uuidString).json")
            let outputURL = FileManager.default.temporaryDirectory.appending(path: "macsweep-cache-\(UUID().uuidString).json")
            do {
                try Self.aiSchemaString.write(to: schemaURL, atomically: true, encoding: .utf8)
                let result = await Task.detached(priority: .userInitiated) {
                    Self.runProcess([
                        "codex",
                        "exec",
                        "--skip-git-repo-check",
                        "--sandbox", "read-only",
                        "--ephemeral",
                        "--output-schema", schemaURL.path,
                        "-o", outputURL.path,
                        prompt
                    ])
                }.value
                if result.status == 0 {
                    let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? result.output
                    if let findings = Self.parseAIFindings(text, source: "AI Analysis") {
                        try? FileManager.default.removeItem(at: schemaURL)
                        try? FileManager.default.removeItem(at: outputURL)
                        return (findings, "Codex CLI", nil)
                    }
                    errors.append("Codex CLI returned an unparseable AI scan response.")
                } else {
                    errors.append(Self.processError("Codex CLI", result))
                }
            } catch {
                errors.append("Codex CLI scan failed: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: schemaURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        return ([], nil, errors.isEmpty ? nil : errors.joined(separator: " "))
    }

    /// POST the largest `~/Library/Application Support` directories to the
    /// Anthropic Messages API and parse the JSON array of suggested cache dirs.
    /// Returns `(findings, error?)` — errors are surfaced, never thrown.
    private func runAnthropicScan(apiKey: String, prompt: String) async -> (findings: [Finding], error: String?) {

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
                  let findings = Self.parseAIFindings(text, source: "AI Analysis") else {
                return ([], "AI scan returned an unparseable response.")
            }
            return (findings, nil)
        } catch {
            return ([], "AI scan failed: \(error.localizedDescription)")
        }
    }

    private static func parseAIFindings(_ text: String, source: String) -> [Finding]? {
        let cleaned = stripMarkdownFence(text)
        guard let arrayData = cleaned.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: arrayData) as? [[String: Any]] else {
            return nil
        }

        return items.compactMap { item -> Finding? in
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
                source: source,
                reason: reason
            )
        }
    }

    private static func stripMarkdownFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shell helper

    private static func executablePath(for command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func runProcess(_ arguments: [String]) -> AIProcessResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return AIProcessResult(status: 127, output: "", error: error.localizedDescription)
        }
        return AIProcessResult(
            status: task.terminationStatus,
            output: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            error: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private static func processError(_ provider: String, _ result: AIProcessResult) -> String {
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(provider) scan failed: \(message)"
    }

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

    private static var aiSchemaString: String {
        """
        {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["path", "size_estimate", "category", "regenerates_automatically"],
            "properties": {
              "path": { "type": "string" },
              "size_estimate": { "type": "string" },
              "category": {
                "type": "string",
                "enum": ["Electron/Chromium", "Package Manager", "Dev Debug Logs", "AI Tool Cache", "Other"]
              },
              "regenerates_automatically": { "type": "boolean" },
              "reason": { "type": "string" }
            }
          }
        }
        """
    }
}

private struct AIProcessResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}
