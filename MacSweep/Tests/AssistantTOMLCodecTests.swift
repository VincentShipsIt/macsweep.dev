import Testing
import Foundation
@testable import MacSweepCore

struct AssistantTOMLCodecTests {
    @Test func providerConfigRoundTripsMiniDefault() throws {
        let rendered = AssistantTOMLCodec.renderProviders(.default)
        let parsed = try AssistantTOMLCodec.parseProviders(rendered)

        #expect(parsed.defaultProvider == .codex)
        #expect(parsed.providers[.codex]?.model == "gpt-5.4-mini")
        #expect(parsed.providers[.codex]?.reasoningEffort == "medium")
        #expect(parsed.fallbackOrder.first == .codex)
    }

    @Test func watchlistsRoundTripPreservesRules() throws {
        let rules = [
            AssistantWatchlistRule(
                id: "slack-cache",
                label: "Slack Cache",
                enabled: true,
                source: "assistant",
                rationale: "Slack cache grows quickly.",
                paths: ["~/Library/Application Support/Slack/Service Worker"],
                excludePaths: ["~/Library/Application Support/Slack/Service Worker/CacheStorage"]
            )
        ]

        let rendered = AssistantTOMLCodec.renderWatchlists(rules)
        let parsed = try AssistantTOMLCodec.parseWatchlists(rendered)

        #expect(parsed == rules)
    }
}
