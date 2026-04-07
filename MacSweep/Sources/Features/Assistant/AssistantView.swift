import SwiftUI
import AppKit

struct AssistantView: View {
    @EnvironmentObject var appState: AppState
    @State private var prompt = ""

    private var assistant: AssistantCoordinator {
        appState.assistant
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HSplitView {
                conversationColumn
                    .frame(minWidth: 520)

                inspectorColumn
                    .frame(minWidth: 300, idealWidth: 340)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assistant")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Plan scans, inspect folders, and maintain persistent watchlists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(assistant.configRootURL)
            } label: {
                Label("Open Config Folder", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    await appState.runAssistantPlan(watchlistPlan)
                }
            } label: {
                Label("Scan Watchlists", systemImage: "scope")
            }
            .buttonStyle(.borderedProminent)
            .disabled(assistant.enabledTargets.isEmpty || appState.isScanning)
        }
        .padding()
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(assistant.messages) { message in
                        AssistantMessageBubble(message: message)
                    }
                }
                .padding()
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )

                HStack {
                    if let lastError = assistant.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    } else {
                        Text("Default provider: Codex on `gpt-5.4-mini` with medium reasoning.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        sendPrompt()
                    } label: {
                        Label(assistant.isSubmitting ? "Thinking..." : "Send", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(assistant.isSubmitting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
    }

    private var inspectorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                providerSection
                currentPlanSection
                watchlistSection
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers")
                .font(.headline)

            ForEach(assistant.providerStatuses) { status in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(status.provider.displayName)
                            .fontWeight(.semibold)

                        Spacer()

                        Text(status.state.rawValue.capitalized)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(providerColor(for: status).opacity(0.12), in: Capsule())
                            .foregroundStyle(providerColor(for: status))
                    }

                    Text("Command: \(status.command)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Model: \(status.model) • Reasoning: \(status.reasoningEffort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let note = status.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private var currentPlanSection: some View {
        if let plan = assistant.currentPlan {
            VStack(alignment: .leading, spacing: 10) {
                Text("Current Plan")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    if let provider = plan.provider {
                        Text("Provider: \(provider.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !plan.modules.isEmpty {
                        AssistantTokenList(title: "Modules", values: plan.modules)
                    }

                    if !plan.customTargets.isEmpty {
                        AssistantTokenList(title: "Custom Targets", values: plan.customTargets.map(\.path))
                    }

                    if !plan.recommendedRules.isEmpty {
                        AssistantTokenList(title: "Suggested Watchlists", values: plan.recommendedRules.map(\.label))
                    }

                    Text(plan.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            Task {
                                await appState.runAssistantPlan(plan)
                            }
                        } label: {
                            Label("Run Scan", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isScanning)

                        Button {
                            Task {
                                await assistant.saveRecommendedRules(from: plan)
                            }
                        } label: {
                            Label("Save Rules", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(plan.recommendedRules.isEmpty)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var watchlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Watchlists")
                    .font(.headline)

                Spacer()

                Text("\(assistant.watchlistRules.filter(\.enabled).count) enabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if assistant.watchlistRules.isEmpty {
                Text("No watchlist rules saved yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(assistant.watchlistRules.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending })) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(rule.label)
                                .fontWeight(.semibold)

                            Spacer()

                            Text(rule.enabled ? "Enabled" : "Disabled")
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background((rule.enabled ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
                                .foregroundStyle(rule.enabled ? .green : .secondary)
                        }

                        Text(rule.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        ForEach(rule.paths, id: \.self) { path in
                            Text(path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
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

    private func providerColor(for status: AssistantProviderStatus) -> Color {
        switch status.state {
        case .ready:
            return .green
        case .installed:
            return .orange
        case .unavailable:
            return .secondary
        case .failed:
            return .red
        }
    }

    private func sendPrompt() {
        let currentPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentPrompt.isEmpty else { return }
        prompt = ""

        Task {
            await assistant.submit(prompt: currentPrompt)
        }
    }
}

private struct AssistantMessageBubble: View {
    let message: AssistantMessage

    var body: some View {
        HStack {
            if message.role == .assistant || message.role == .system {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(message.text)
                .font(.body)
                .textSelection(.enabled)

            if let plan = message.plan {
                Divider()

                if !plan.modules.isEmpty {
                    AssistantTokenList(title: "Modules", values: plan.modules)
                }

                if !plan.customTargets.isEmpty {
                    AssistantTokenList(title: "Targets", values: plan.customTargets.map(\.path))
                }
            }
        }
        .padding(12)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 14))
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
            return Color.blue.opacity(0.08)
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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
