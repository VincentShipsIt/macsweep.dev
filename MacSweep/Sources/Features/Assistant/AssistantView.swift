import SwiftUI

struct AssistantView: View {
    @EnvironmentObject var appState: AppState
    @State private var prompt = ""
    @FocusState private var isComposerFocused: Bool

    private let promptSuggestions = [
        AssistantPromptSuggestion(
            icon: "folder.badge.gearshape",
            title: "Inspect Downloads",
            prompt: "Inspect ~/Downloads for large old files and safe cleanup candidates."
        ),
        AssistantPromptSuggestion(
            icon: "sparkles.rectangle.stack",
            title: "Review Caches",
            prompt: "Plan a safe scan for user caches, browser caches, and service worker data."
        ),
        AssistantPromptSuggestion(
            icon: "scope",
            title: "Watch a Folder",
            prompt: "Always watch ~/Library/Logs and suggest safe exclusions."
        ),
        AssistantPromptSuggestion(
            icon: "photo.on.rectangle.angled",
            title: "Find Similar Photos",
            prompt: "Look for duplicate and similar photos I can review before deleting."
        ),
    ]

    private var assistant: AssistantCoordinator {
        appState.assistant
    }

    var body: some View {
        FeaturePageShell(
            title: "Assistant",
            subtitle: "Plan scans, inspect folders, and maintain watchlists.",
            trailing: AnyView(headerActions)
        ) {
            conversationColumn
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            SettingsLink {
                Label("Assistant Settings", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help("Assistant Settings")

            Button {
                Task {
                    await appState.runAssistantPlan(watchlistPlan)
                }
            } label: {
                Label("Scan Watchlists", systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(
                        assistant.enabledTargets.isEmpty || appState.isScanning ? .secondary : MacSweepTheme.accent
                    )
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .disabled(assistant.enabledTargets.isEmpty || appState.isScanning)
            .help("Scan Watchlists")
        }
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(assistant.messages) { message in
                            AssistantMessageBubble(
                                message: message,
                                isScanning: appState.isScanning,
                                onRunPlan: { plan in
                                    Task {
                                        await appState.runAssistantPlan(plan)
                                    }
                                },
                                onSaveRules: { plan in
                                    Task {
                                        await assistant.saveRecommendedRules(from: plan)
                                    }
                                }
                            )
                            .id(message.id)

                            if message.role == .system && assistant.messages.count == 1 {
                                AssistantPromptSuggestionGrid(
                                    suggestions: promptSuggestions,
                                    onSelect: useSuggestion
                                )
                            }
                        }

                        if assistant.isSubmitting {
                            AssistantThinkingBubble()
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("conversation-bottom")
                    }
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .background(MacSweepTheme.panel.opacity(0.45))
                .onChange(of: assistant.messages.count) {
                    scrollToBottom(proxy)
                }
                .onChange(of: assistant.isSubmitting) {
                    scrollToBottom(proxy)
                }
            }

            Divider()

            composer
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lastError = assistant.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Ask the assistant to plan a scan or inspect a folder...",
                    text: $prompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($isComposerFocused)
                .onSubmit {
                    guard !isSendDisabled else { return }
                    sendPrompt()
                }

                Button(action: sendPrompt) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(
                                isSendDisabled ? Color.secondary.opacity(0.18) : MacSweepTheme.accent
                            )
                        )
                        .foregroundStyle(isSendDisabled ? Color.secondary : Color.black)
                }
                .buttonStyle(.plain)
                .disabled(isSendDisabled)
                .help(assistant.isSubmitting ? "Thinking..." : "Send")
            }
            .padding(12)
            .macSweepCard(radius: 12)
        }
    }

    private var isSendDisabled: Bool {
        assistant.isSubmitting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var watchlistPlan: AssistantScanPlan {
        AssistantScanPlan(
            provider: nil,
            prompt: "Scan saved watchlists",
            modules: [],
            customTargets: assistant.enabledTargets,
            recommendedRules: [],
            explanation: "Scanning all enabled persistent watchlists from watchlists.toml.",
            usedFallback: true
        )
    }

    private func useSuggestion(_ suggestion: AssistantPromptSuggestion) {
        prompt = suggestion.prompt
        isComposerFocused = true
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
        }
    }

    private func sendPrompt() {
        guard !assistant.isSubmitting else { return }
        let currentPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentPrompt.isEmpty else { return }
        prompt = ""

        Task {
            await assistant.submit(prompt: currentPrompt)
        }
    }
}

private struct AssistantPromptSuggestion: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let prompt: String
}

private struct AssistantPromptSuggestionGrid: View {
    let suggestions: [AssistantPromptSuggestion]
    let onSelect: (AssistantPromptSuggestion) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 240), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(suggestions) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    AssistantPromptSuggestionCard(suggestion: suggestion)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AssistantPromptSuggestionCard: View {
    let suggestion: AssistantPromptSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MacSweepTheme.accent)
                .frame(width: 30, height: 30)
                .background(MacSweepTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)

                Text(suggestion.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Image(systemName: "arrow.up.forward")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .macSweepCard(radius: MacSweepTheme.smallRadius)
    }
}

private struct AssistantMessageBubble: View {
    let message: AssistantMessage
    let isScanning: Bool
    let onRunPlan: (AssistantScanPlan) -> Void
    let onSaveRules: (AssistantScanPlan) -> Void

    var body: some View {
        HStack {
            if message.role == .assistant || message.role == .system {
                bubble
                Spacer(minLength: 64)
            } else {
                Spacer(minLength: 64)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(message.text)
                .font(.body)
                .textSelection(.enabled)

            if let plan = message.plan {
                Divider()

                if let provider = plan.provider {
                    Label(provider.displayName, systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if plan.usedFallback {
                    Label("Local fallback", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !plan.modules.isEmpty {
                    AssistantTokenList(title: "Modules", values: plan.modules)
                }

                if !plan.customTargets.isEmpty {
                    AssistantTokenList(title: "Targets", values: plan.customTargets.map(\.path))
                }

                if !plan.recommendedRules.isEmpty {
                    AssistantTokenList(title: "Suggested Watchlists", values: plan.recommendedRules.map(\.label))
                }

                HStack(spacing: 8) {
                    Button {
                        onRunPlan(plan)
                    } label: {
                        Label("Run Scan", systemImage: "play.fill")
                    }
                    .glassButton(prominent: true)
                    .controlSize(.small)
                    .disabled(isScanning)

                    Button {
                        onSaveRules(plan)
                    } label: {
                        Label("Save Rules", systemImage: "square.and.arrow.down")
                    }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(plan.recommendedRules.isEmpty)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: message.role == .user ? 620 : 760, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(MacSweepTheme.glassCardStroke.opacity(message.role == .user ? 0.45 : 0.8), lineWidth: 1)
        }
    }

    private var title: String {
        switch message.role {
        case .system:
            return "System"
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        }
    }

    private var backgroundColor: Color {
        switch message.role {
        case .system:
            return Color.secondary.opacity(0.08)
        case .user:
            return Color.accentColor.opacity(0.16)
        case .assistant:
            return MacSweepTheme.glassCardTint
        }
    }
}

private struct AssistantThinkingBubble: View {
    var body: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)

                Text("Thinking...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .macSweepCard(radius: 14)

            Spacer(minLength: 64)
        }
    }
}

private struct AssistantTokenList: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(items: values)
        }
    }
}

private struct FlowLayout: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
