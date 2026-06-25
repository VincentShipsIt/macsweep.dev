import Foundation
import Combine

enum AssistantConversationError: LocalizedError {
    case invalidResponse
    case unknownProvider(AssistantProviderKind)
    case processFailed(provider: AssistantProviderKind, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The provider returned an unreadable assistant plan."
        case .unknownProvider(let provider):
            return "No configuration found for \(provider.displayName)."
        case .processFailed(let provider, let message):
            return "\(provider.displayName) failed: \(message)"
        }
    }
}

private struct AssistantPlanPayload: Codable {
    struct Target: Codable {
        let path: String
        let label: String?
        let excludePaths: [String]?
    }

    struct Rule: Codable {
        let id: String?
        let label: String
        let rationale: String
        let paths: [String]
        let excludePaths: [String]?
    }

    let explanation: String
    let modules: [String]
    let customTargets: [Target]
    let recommendedRules: [Rule]
}

struct AssistantProviderDetector {
    func detect(using config: AssistantProvidersConfiguration) -> [AssistantProviderStatus] {
        AssistantProviderKind.allCases.compactMap { provider -> AssistantProviderStatus? in
            // detect() is non-throwing, so an unconfigured provider is skipped
            // rather than crashing on a force-unwrap. The bundled default config
            // covers every kind, so in practice nothing is dropped.
            guard let providerConfig = config.providers[provider]
                ?? AssistantProvidersConfiguration.default.providers[provider] else { return nil }
            let installed = executablePath(for: providerConfig.command) != nil
            let configured = configLocation(for: provider) != nil
            let state: AssistantProviderState

            if installed && configured {
                state = .ready
            } else if installed {
                state = .installed
            } else {
                state = .unavailable
            }

            return AssistantProviderStatus(
                provider: provider,
                command: providerConfig.command,
                state: state,
                installed: installed,
                configured: configured,
                model: providerConfig.model,
                reasoningEffort: providerConfig.reasoningEffort,
                note: configLocation(for: provider)?.path
            )
        }
    }

    private func executablePath(for command: String) -> String? {
        let path = Foundation.ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func configLocation(for provider: AssistantProviderKind) -> URL? {
        switch provider {
        case .codex:
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .claude:
            let configDir = Foundation.ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
                .map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
            return FileManager.default.fileExists(atPath: configDir.path) ? configDir : nil
        case .openai:
            return nil
        }
    }
}

actor AssistantConversationService {
    func plan(
        prompt: String,
        moduleCatalog: [AssistantModuleContext],
        existingRules: [AssistantWatchlistRule],
        config: AssistantProvidersConfiguration,
        statuses: [AssistantProviderStatus]
    ) async -> AssistantScanPlan {
        let orderedProviders = providerOrder(config: config, statuses: statuses)
        var lastError: Error?

        for provider in orderedProviders {
            do {
                return try await planWithProvider(
                    provider,
                    prompt: prompt,
                    moduleCatalog: moduleCatalog,
                    existingRules: existingRules,
                    config: config
                )
            } catch {
                lastError = error
            }
        }

        let fallback = heuristicPlan(prompt: prompt, moduleCatalog: moduleCatalog)
        let suffix = lastError.map { "\n\nProvider fallback reason: \($0.localizedDescription)" } ?? ""

        return AssistantScanPlan(
            provider: nil,
            prompt: prompt,
            modules: fallback.modules,
            customTargets: fallback.customTargets,
            recommendedRules: fallback.recommendedRules,
            explanation: fallback.explanation + suffix,
            usedFallback: true
        )
    }

    private func providerOrder(
        config: AssistantProvidersConfiguration,
        statuses: [AssistantProviderStatus]
    ) -> [AssistantProviderKind] {
        let statusMap = Dictionary(uniqueKeysWithValues: statuses.map { ($0.provider, $0) })
        let preferred = [config.defaultProvider] + config.fallbackOrder

        return Array(NSOrderedSet(array: preferred)).compactMap { $0 as? AssistantProviderKind }.filter { provider in
            guard let entry = config.providers[provider], entry.enabled else { return false }
            return statusMap[provider]?.installed == true
        }
    }

    private func planWithProvider(
        _ provider: AssistantProviderKind,
        prompt: String,
        moduleCatalog: [AssistantModuleContext],
        existingRules: [AssistantWatchlistRule],
        config: AssistantProvidersConfiguration
    ) async throws -> AssistantScanPlan {
        guard let providerConfig = config.providers[provider]
            ?? AssistantProvidersConfiguration.default.providers[provider] else {
            throw AssistantConversationError.unknownProvider(provider)
        }
        let schemaURL = try writeSchemaFile()
        let outputURL = FileManager.default.temporaryDirectory.appending(path: "macsweep-assistant-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: schemaURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let promptText = makePrompt(prompt: prompt, moduleCatalog: moduleCatalog, existingRules: existingRules)
        let result: String

        switch provider {
        case .codex:
            result = try runProcess(
                launchPath: "/usr/bin/env",
                arguments: [
                    providerConfig.command,
                    "exec",
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "--ephemeral",
                    "-m", providerConfig.model,
                    "-c", "model_reasoning_effort=\"\(providerConfig.reasoningEffort)\"",
                    "--output-schema", schemaURL.path,
                    "-o", outputURL.path,
                    promptText,
                ]
            )
            _ = result
        case .claude:
            result = try runProcess(
                launchPath: "/usr/bin/env",
                arguments: [
                    providerConfig.command,
                    "-p",
                    "--model", providerConfig.model,
                    "--effort", providerConfig.reasoningEffort,
                    "--json-schema", schemaString,
                    promptText,
                ]
            )
            try result.write(to: outputURL, atomically: true, encoding: .utf8)
        case .openai:
            throw AssistantConversationError.processFailed(provider: provider, message: "The openai CLI is not configured in v1.")
        }

        let payloadData = try Data(contentsOf: outputURL)
        let payload = try JSONDecoder().decode(AssistantPlanPayload.self, from: payloadData)

        return AssistantScanPlan(
            provider: provider,
            prompt: prompt,
            modules: Array(NSOrderedSet(array: payload.modules)).compactMap { $0 as? String },
            customTargets: payload.customTargets.map {
                AssistantScanTarget(
                    path: $0.path,
                    label: $0.label ?? URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath).lastPathComponent,
                    sourceRuleID: nil,
                    excludePaths: $0.excludePaths ?? []
                )
            },
            recommendedRules: payload.recommendedRules.map {
                AssistantWatchlistRule(
                    id: $0.id ?? sanitizedRuleID(label: $0.label),
                    label: $0.label,
                    enabled: true,
                    source: "assistant",
                    rationale: $0.rationale,
                    paths: $0.paths,
                    excludePaths: $0.excludePaths ?? []
                )
            },
            explanation: payload.explanation,
            usedFallback: false
        )
    }

    private func heuristicPlan(
        prompt: String,
        moduleCatalog: [AssistantModuleContext]
    ) -> (modules: [String], customTargets: [AssistantScanTarget], recommendedRules: [AssistantWatchlistRule], explanation: String) {
        let lowercasedPrompt = prompt.lowercased()
        var modules: [String] = []

        let keywordMap: [(String, [String])] = [
            ("cache", ["system-cache", "service-workers"]),
            ("caches", ["system-cache", "service-workers"]),
            ("trash", ["trash-bins"]),
            ("browser", ["browser-chrome", "browser-safari", "browser-firefox", "browser-brave", "browser-arc"]),
            ("service worker", ["service-workers"]),
            ("docker", ["docker"]),
            ("node_modules", ["dev-tools", "package-managers"]),
            ("npm", ["package-managers"]),
            ("yarn", ["package-managers"]),
            ("pnpm", ["package-managers"]),
            ("bun", ["package-managers"]),
            ("duplicate", ["duplicates"]),
            ("duplicates", ["duplicates"]),
            ("photo", ["similar-photos"]),
            ("photos", ["similar-photos"]),
            ("large", ["large-files"]),
            ("icloud", ["cloud-cleanup"]),
            ("cloud", ["cloud-cleanup"]),
            ("mail", ["mail-attachments"]),
            ("privacy", ["privacy"]),
        ]

        for (keyword, mappedModules) in keywordMap where lowercasedPrompt.contains(keyword) {
            modules.append(contentsOf: mappedModules)
        }

        let validModules = Set(moduleCatalog.map(\.id))
        modules = Array(NSOrderedSet(array: modules)).compactMap { $0 as? String }.filter { validModules.contains($0) }

        let customTargets = extractPaths(from: prompt).map {
            AssistantScanTarget(
                path: $0,
                label: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).lastPathComponent,
                sourceRuleID: nil,
                excludePaths: []
            )
        }

        let shouldRecommendRule = lowercasedPrompt.contains("always")
            || lowercasedPrompt.contains("watch")
            || lowercasedPrompt.contains("watchlist")

        let recommendedRules = shouldRecommendRule ? customTargets.map {
            AssistantWatchlistRule(
                id: sanitizedRuleID(label: $0.label),
                label: $0.label,
                enabled: true,
                source: "assistant",
                rationale: "Derived from the user's request: \(prompt)",
                paths: [$0.path],
                excludePaths: $0.excludePaths
            )
        } : []

        let explanation: String
        if !customTargets.isEmpty || !modules.isEmpty {
            explanation = "I mapped the request into existing cleanup modules and direct scan targets using local heuristics because no verified LLM provider answered in time."
        } else {
            explanation = "I could not map the request to a specific module, so I prepared an empty plan instead of guessing."
        }

        return (modules, customTargets, recommendedRules, explanation)
    }

    private func extractPaths(from prompt: String) -> [String] {
        let pattern = "(~/[^\\s,]+|/[^\\s,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        return regex.matches(in: prompt, range: range).compactMap {
            Range($0.range, in: prompt).map { String(prompt[$0]) }
        }
    }

    private func makePrompt(
        prompt: String,
        moduleCatalog: [AssistantModuleContext],
        existingRules: [AssistantWatchlistRule]
    ) -> String {
        let moduleText = moduleCatalog
            .sorted { $0.id < $1.id }
            .map { "- \($0.id): \($0.name) | \($0.description)" }
            .joined(separator: "\n")

        let watchlistText = existingRules.isEmpty
            ? "- none"
            : existingRules.map {
                "- \($0.id): \($0.label) | enabled=\($0.enabled) | paths=\($0.paths.joined(separator: ", "))"
            }.joined(separator: "\n")

        return """
        You are planning cleanup scans for MacSweep, a macOS cleaner.

        Rules:
        - Prefer existing module IDs when they fit.
        - Use customTargets only for explicit or strongly implied filesystem paths.
        - recommendedRules should only include paths the user appears to want watched persistently.
        - Never invent unsafe system paths like /System, /Applications, /private, ~/Library/Keychains, ~/.ssh.
        - Keep explanations concise and operational.

        Available modules:
        \(moduleText)

        Existing watchlist rules:
        \(watchlistText)

        User request:
        \(prompt)
        """
    }

    private func writeSchemaFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "macsweep-assistant-schema-\(UUID().uuidString).json")
        try schemaString.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runProcess(launchPath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let provider = arguments.first.flatMap(AssistantProviderKind.init(rawValue:)) ?? .codex
            throw AssistantConversationError.processFailed(
                provider: provider,
                message: error.isEmpty ? output : error
            )
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedRuleID(label: String) -> String {
        let value = label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return value.isEmpty ? "assistant-rule-\(UUID().uuidString)" : value
    }

    private var schemaString: String {
        """
        {
          "type": "object",
          "required": ["explanation", "modules", "customTargets", "recommendedRules"],
          "properties": {
            "explanation": { "type": "string" },
            "modules": {
              "type": "array",
              "items": { "type": "string" }
            },
            "customTargets": {
              "type": "array",
              "items": {
                "type": "object",
                "required": ["path"],
                "properties": {
                  "path": { "type": "string" },
                  "label": { "type": "string" },
                  "excludePaths": {
                    "type": "array",
                    "items": { "type": "string" }
                  }
                }
              }
            },
            "recommendedRules": {
              "type": "array",
              "items": {
                "type": "object",
                "required": ["label", "rationale", "paths"],
                "properties": {
                  "id": { "type": "string" },
                  "label": { "type": "string" },
                  "rationale": { "type": "string" },
                  "paths": {
                    "type": "array",
                    "items": { "type": "string" }
                  },
                  "excludePaths": {
                    "type": "array",
                    "items": { "type": "string" }
                  }
                }
              }
            }
          }
        }
        """
    }
}

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published private(set) var providerConfig = AssistantProvidersConfiguration.default
    @Published private(set) var providerStatuses: [AssistantProviderStatus] = []
    @Published private(set) var watchlistRules: [AssistantWatchlistRule] = []
    @Published private(set) var messages: [AssistantMessage] = [
        AssistantMessage(
            role: .system,
            text: "Ask MacSweep to scan cache folders, inspect a path, or add persistent watchlists."
        )
    ]
    @Published private(set) var currentPlan: AssistantScanPlan?
    @Published private(set) var isSubmitting = false
    @Published private(set) var lastError: String?

    private let repository: AssistantConfigRepository
    private let detector = AssistantProviderDetector()
    private let service = AssistantConversationService()
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: CInt = -1

    init(repository: AssistantConfigRepository = AssistantConfigRepository()) {
        self.repository = repository

        Task {
            await reload()
            await startWatchingConfigDirectory()
        }
    }

    deinit {
        watcher?.cancel()
        if watchedDescriptor >= 0 {
            close(watchedDescriptor)
        }
    }

    func reload() async {
        do {
            let (providers, rules) = try await repository.loadSnapshot()
            providerConfig = providers
            watchlistRules = rules
            providerStatuses = detector.detect(using: providers)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func submit(prompt: String) async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        messages.append(AssistantMessage(role: .user, text: trimmedPrompt))
        isSubmitting = true
        defer { isSubmitting = false }

        let modules = await moduleCatalog()
        let plan = await service.plan(
            prompt: trimmedPrompt,
            moduleCatalog: modules,
            existingRules: watchlistRules,
            config: providerConfig,
            statuses: providerStatuses
        )

        currentPlan = plan
        messages.append(
            AssistantMessage(
                role: .assistant,
                text: plan.explanation,
                plan: plan
            )
        )
    }

    func saveRecommendedRules(from plan: AssistantScanPlan? = nil) async {
        guard let plan = plan ?? currentPlan else { return }
        guard !plan.recommendedRules.isEmpty else { return }

        let mergedRules = mergeRules(existing: watchlistRules, newRules: plan.recommendedRules)

        do {
            try await repository.saveWatchlistRules(mergedRules)
            await reload()
            messages.append(AssistantMessage(
                role: .system,
                text: "Saved \(plan.recommendedRules.count) watchlist rule(s) to watchlists.toml."
            ))
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func saveProviderConfiguration(_ config: AssistantProvidersConfiguration) async -> Bool {
        do {
            try await repository.saveProviders(config)
            await reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    var enabledTargets: [AssistantScanTarget] {
        watchlistRules
            .filter(\.enabled)
            .flatMap { rule in
                rule.paths.map {
                    AssistantScanTarget(
                        path: $0,
                        label: rule.label,
                        sourceRuleID: rule.id,
                        excludePaths: rule.excludePaths
                    )
                }
            }
    }

    var configRootURL: URL {
        repository.rootURL
    }

    private func moduleCatalog() async -> [AssistantModuleContext] {
        let modules = await ScanEngine().registeredModules()
        return modules.map {
            AssistantModuleContext(id: $0.id, name: $0.name, description: $0.description)
        }
    }

    private func mergeRules(
        existing: [AssistantWatchlistRule],
        newRules: [AssistantWatchlistRule]
    ) -> [AssistantWatchlistRule] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for rule in newRules {
            if var existingRule = merged[rule.id] {
                let combinedPaths = Array(NSOrderedSet(array: existingRule.paths + rule.paths)).compactMap { $0 as? String }
                let combinedExcludes = Array(NSOrderedSet(array: existingRule.excludePaths + rule.excludePaths)).compactMap { $0 as? String }
                existingRule.paths = combinedPaths
                existingRule.excludePaths = combinedExcludes
                existingRule.enabled = true
                existingRule.rationale = rule.rationale
                existingRule.source = rule.source
                merged[rule.id] = existingRule
            } else {
                merged[rule.id] = rule
            }
        }

        return Array(merged.values)
    }

    private func startWatchingConfigDirectory() async {
        guard watcher == nil else { return }

        let descriptor = open(repository.rootURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        watchedDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.reload()
            }
        }

        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        watcher = source
        source.resume()
    }
}
