import Foundation

actor AssistantConfigRepository {
    nonisolated let rootURL: URL
    nonisolated let assistantDirectoryURL: URL
    nonisolated let watchlistsDirectoryURL: URL
    nonisolated let providersURL: URL
    nonisolated let watchlistsURL: URL
    nonisolated let readmeURL: URL

    init(rootURL: URL? = nil) {
        let baseURL = rootURL ?? Self.defaultRootURL()
        self.rootURL = baseURL
        self.assistantDirectoryURL = baseURL.appending(path: "assistant", directoryHint: .isDirectory)
        self.watchlistsDirectoryURL = baseURL.appending(path: "watchlists", directoryHint: .isDirectory)
        self.providersURL = assistantDirectoryURL.appending(path: "providers.toml")
        self.watchlistsURL = watchlistsDirectoryURL.appending(path: "watchlists.toml")
        self.readmeURL = watchlistsDirectoryURL.appending(path: "README.md")
    }

    func bootstrapIfNeeded() throws {
        try FileManager.default.createDirectory(at: assistantDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: watchlistsDirectoryURL, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: providersURL.path) {
            try AssistantTOMLCodec.renderProviders(.default)
                .write(to: providersURL, atomically: true, encoding: .utf8)
        }

        if !FileManager.default.fileExists(atPath: watchlistsURL.path) {
            try AssistantTOMLCodec.renderWatchlists(Self.defaultWatchlistRules())
                .write(to: watchlistsURL, atomically: true, encoding: .utf8)
        }

        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            try Self.watchlistReadme.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }

    func loadProviders() throws -> AssistantProvidersConfiguration {
        try bootstrapIfNeeded()
        let content = try String(contentsOf: providersURL, encoding: .utf8)
        return try AssistantTOMLCodec.parseProviders(content)
    }

    func loadWatchlistRules() throws -> [AssistantWatchlistRule] {
        try bootstrapIfNeeded()
        let content = try String(contentsOf: watchlistsURL, encoding: .utf8)
        return try AssistantTOMLCodec.parseWatchlists(content)
    }

    func loadSnapshot() throws -> (AssistantProvidersConfiguration, [AssistantWatchlistRule]) {
        let providers = try loadProviders()
        let rules = try loadWatchlistRules()
        return (providers, rules)
    }

    func saveWatchlistRules(_ rules: [AssistantWatchlistRule]) throws {
        try bootstrapIfNeeded()
        try AssistantTOMLCodec.renderWatchlists(rules)
            .write(to: watchlistsURL, atomically: true, encoding: .utf8)
    }

    func saveProviders(_ config: AssistantProvidersConfiguration) throws {
        try bootstrapIfNeeded()
        try AssistantTOMLCodec.renderProviders(config)
            .write(to: providersURL, atomically: true, encoding: .utf8)
    }

    private static func defaultRootURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/macsweep.dev", directoryHint: .isDirectory)
    }

    private static func defaultWatchlistRules() -> [AssistantWatchlistRule] {
        [
            AssistantWatchlistRule(
                id: "user-caches",
                label: "User Caches",
                enabled: true,
                source: "seed",
                rationale: "Common reclaimable cache files inside the user Library cache tree.",
                paths: ["~/Library/Caches"],
                excludePaths: [
                    "~/Library/Caches/CloudKit",
                    "~/Library/Caches/com.apple.nsurlsessiond",
                    "~/Library/Caches/com.apple.bird",
                ]
            ),
            AssistantWatchlistRule(
                id: "application-logs",
                label: "Application Logs",
                enabled: true,
                source: "seed",
                rationale: "Application logs are usually safe to review and purge when they grow large.",
                paths: ["~/Library/Logs"],
                excludePaths: []
            ),
            AssistantWatchlistRule(
                id: "saved-app-state",
                label: "Saved App State",
                enabled: false,
                source: "seed",
                rationale: "Saved app state can be noisy but sometimes useful; keep it opt-in.",
                paths: ["~/Library/Saved Application State"],
                excludePaths: []
            ),
        ]
    }

    private static let watchlistReadme = """
    # MacSweep Watchlists

    `watchlists.toml` is the authoritative config file for assistant-managed watchlists.

    Use it to declare folders MacSweep should keep scanning for cache, junk, or temp data.

    Rules:

    - `paths` are scan roots. MacSweep scans inside them, it does not blindly delete the root folder.
    - `exclude_paths` are exact path prefixes MacSweep should skip under a rule.
    - `source` is descriptive metadata only.
    - Deletion still goes through MacSweep safety checks and confirmation dialogs.

    Example:

    ```toml
    [[rules]]
    id = "slack-service-worker"
    label = "Slack Service Worker"
    enabled = true
    source = "assistant"
    rationale = "Electron service worker caches often grow large."
    paths = ["~/Library/Application Support/Slack/Service Worker"]
    exclude_paths = []
    ```
    """
}
