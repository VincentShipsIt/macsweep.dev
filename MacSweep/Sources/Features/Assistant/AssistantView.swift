import SwiftUI
import AppKit

struct AssistantView: View {
    @EnvironmentObject var appState: AppState
    @State private var prompt = ""

    private var assistant: AssistantCoordinator {
        appState.assistant
    }

    var body: some View {
        FeaturePageShell(
            title: "Assistant",
            subtitle: "Plan scans, inspect folders, and maintain watchlists.",
            trailing: AnyView(
                Button {
                    Task {
                        await appState.runAssistantPlan(watchlistPlan)
                    }
                } label: {
                    Label("Scan Watchlists", systemImage: "scope")
                }
                .glassButton(prominent: true)
                .controlSize(.small)
                .disabled(assistant.enabledTargets.isEmpty || appState.isScanning)
            )
        ) {
            HSplitView {
                conversationColumn
                    .frame(minWidth: 520)

                inspectorColumn
                    .frame(minWidth: 300, idealWidth: 340)
            }
        }
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
            .background(MacSweepTheme.panel.opacity(0.65))

            Divider()

            composer
                .padding()
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

            VStack(spacing: 8) {
                TextField(
                    "Ask the assistant to plan a scan or inspect a folder…",
                    text: $prompt,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .onSubmit {
                    guard !isSendDisabled else { return }
                    sendPrompt()
                }

                HStack(spacing: 8) {
                    providerPicker

                    Button {
                        NSWorkspace.shared.open(assistant.configRootURL)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open Config Folder")

                    Spacer()

                    Button(action: sendPrompt) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(
                                    isSendDisabled ? Color.secondary.opacity(0.18) : MacSweepTheme.accent
                                )
                            )
                            .foregroundStyle(isSendDisabled ? Color.secondary : Color.black)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSendDisabled)
                    .help(assistant.isSubmitting ? "Thinking…" : "Send")
                }
            }
            .padding(10)
            .background(MacSweepTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(MacSweepTheme.divider, lineWidth: 1)
            )
        }
    }

    private var providerPicker: some View {
        let kind = assistant.providerConfig.defaultProvider
        let model = assistant.providerConfig.providers[kind]?.model

        return HStack(spacing: 5) {
            Image(systemName: "cpu")
                .font(.caption2)
            Text(model.map { "\(kind.displayName) · \($0)" } ?? kind.displayName)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MacSweepTheme.panelStrong, in: Capsule())
        .help("Default provider · model · reasoning. Configure in providers.toml.")
    }

    private var isSendDisabled: Bool {
        assistant.isSubmitting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        .background(Color.clear)
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
                .macSweepPanel()
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
                        .glassButton(prominent: true)
                        .disabled(appState.isScanning)

                        Button {
                            Task {
                                await assistant.saveRecommendedRules(from: plan)
                            }
                        } label: {
                            Label("Save Rules", systemImage: "square.and.arrow.down")
                        }
                        .glassButton()
                        .disabled(plan.recommendedRules.isEmpty)
                    }
                }
                .padding(12)
                .macSweepPanel()
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
                .macSweepPanel()
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
        guard !assistant.isSubmitting else { return }
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
