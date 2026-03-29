import Foundation

enum AssistantProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .openai:
            return "OpenAI CLI"
        }
    }
}

enum AssistantProviderState: String, Codable, Sendable {
    case ready
    case installed
    case unavailable
    case failed
}

struct AssistantProviderConfiguration: Sendable, Equatable {
    var enabled: Bool
    var command: String
    var model: String
    var reasoningEffort: String
}

struct AssistantProvidersConfiguration: Sendable, Equatable {
    var defaultProvider: AssistantProviderKind
    var fallbackOrder: [AssistantProviderKind]
    var providers: [AssistantProviderKind: AssistantProviderConfiguration]

    static let `default` = AssistantProvidersConfiguration(
        defaultProvider: .codex,
        fallbackOrder: [.codex, .claude, .openai],
        providers: [
            .codex: AssistantProviderConfiguration(
                enabled: true,
                command: "codex",
                model: "gpt-5.4-mini",
                reasoningEffort: "medium"
            ),
            .claude: AssistantProviderConfiguration(
                enabled: true,
                command: "claude",
                model: "sonnet",
                reasoningEffort: "medium"
            ),
            .openai: AssistantProviderConfiguration(
                enabled: false,
                command: "openai",
                model: "gpt-5.4-mini",
                reasoningEffort: "medium"
            ),
        ]
    )
}

struct AssistantProviderStatus: Identifiable, Sendable, Equatable {
    let provider: AssistantProviderKind
    let command: String
    let state: AssistantProviderState
    let installed: Bool
    let configured: Bool
    let model: String
    let reasoningEffort: String
    let note: String?

    var id: AssistantProviderKind { provider }
}

struct AssistantWatchlistRule: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var label: String
    var enabled: Bool
    var source: String
    var rationale: String
    var paths: [String]
    var excludePaths: [String]

    var displaySource: String {
        source.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

struct AssistantScanTarget: Hashable, Sendable {
    let path: String
    let label: String
    let sourceRuleID: String?
    let excludePaths: [String]
}

struct AssistantScanPlan: Identifiable, Sendable {
    let id: UUID
    let provider: AssistantProviderKind?
    let prompt: String
    let modules: [String]
    let customTargets: [AssistantScanTarget]
    let recommendedRules: [AssistantWatchlistRule]
    let explanation: String
    let usedFallback: Bool

    init(
        id: UUID = UUID(),
        provider: AssistantProviderKind?,
        prompt: String,
        modules: [String],
        customTargets: [AssistantScanTarget],
        recommendedRules: [AssistantWatchlistRule],
        explanation: String,
        usedFallback: Bool
    ) {
        self.id = id
        self.provider = provider
        self.prompt = prompt
        self.modules = modules
        self.customTargets = customTargets
        self.recommendedRules = recommendedRules
        self.explanation = explanation
        self.usedFallback = usedFallback
    }
}

enum AssistantMessageRole: String, Sendable {
    case system
    case user
    case assistant
}

struct AssistantMessage: Identifiable, Sendable {
    let id: UUID
    let role: AssistantMessageRole
    let text: String
    let timestamp: Date
    let plan: AssistantScanPlan?

    init(
        id: UUID = UUID(),
        role: AssistantMessageRole,
        text: String,
        timestamp: Date = Date(),
        plan: AssistantScanPlan? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.plan = plan
    }
}

struct AssistantModuleContext: Sendable {
    let id: String
    let name: String
    let description: String
}
