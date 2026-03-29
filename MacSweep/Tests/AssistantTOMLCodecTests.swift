import XCTest
@testable import MacSweepCore

final class AssistantTOMLCodecTests: XCTestCase {
    func testProviderConfigRoundTripsMiniDefault() throws {
        let rendered = AssistantTOMLCodec.renderProviders(.default)
        let parsed = try AssistantTOMLCodec.parseProviders(rendered)

        XCTAssertEqual(parsed.defaultProvider, .codex)
        XCTAssertEqual(parsed.providers[.codex]?.model, "gpt-5.4-mini")
        XCTAssertEqual(parsed.providers[.codex]?.reasoningEffort, "medium")
        XCTAssertEqual(parsed.fallbackOrder.first, .codex)
    }

    func testWatchlistsRoundTripPreservesRules() throws {
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

        XCTAssertEqual(parsed, rules)
    }
}
