import SwiftUI

/// Login Items & Launch Agents Manager with AI analysis
struct LoginItemsView: View {
    @StateObject private var service = LoginItemsService.shared
    @State private var showDeleteConfirm: LoginItem? = nil

    var body: some View {
        FeaturePageShell(
            title: "Login Items",
            subtitle: "Manage apps and agents that run at startup.",
            trailing: AnyView(
                Button {
                    Task { await service.analyzeWithAI() }
                } label: {
                    if service.isAnalyzing {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Analyzing…")
                        }
                    } else {
                        Label("Analyze with AI", systemImage: "sparkles")
                    }
                }
                .glassButton(prominent: true)
                .controlSize(.small)
                .disabled(service.isAnalyzing || service.items.isEmpty)
            )
        ) {
            ScrollView {
                VStack(spacing: 24) {
                    if service.isLoading {
                        loadingView
                    } else if service.items.isEmpty {
                        emptyState
                    } else {
                        itemsList
                    }
                }
                .padding()
            }
        }
        .task {
            if service.items.isEmpty {
                await service.scan()
            }
        }
        .alert("Delete item?", isPresented: .init(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let item = showDeleteConfirm {
                    Task { await service.delete(item) }
                }
                showDeleteConfirm = nil
            }
            Button("Cancel", role: .cancel) { showDeleteConfirm = nil }
        } message: {
            if let item = showDeleteConfirm {
                Text("This will remove \"\(item.name)\" permanently.")
            }
        }
        .errorAlert(message: $service.errorMessage)
    }

    // MARK: - Items List (grouped by type)

    private var itemsList: some View {
        VStack(spacing: 20) {
            ForEach(LoginItemType.allCases, id: \.self) { type in
                let group = service.items.filter { $0.type == type }
                if !group.isEmpty {
                    groupSection(type: type, items: group)
                }
            }
        }
    }

    @ViewBuilder
    private func groupSection(type: LoginItemType, items: [LoginItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(type.rawValue)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 4) {
                ForEach(items) { item in
                    LoginItemRow(item: item, onToggle: { enabled in
                        Task { await service.setEnabled(enabled, for: item) }
                    }, onDelete: {
                        showDeleteConfirm = item
                    })
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Loading / Empty

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Scanning startup items…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No startup items found")
                .font(.headline)
            Text("Nothing is set to launch at startup")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - Login Item Row

struct LoginItemRow: View {
    let item: LoginItem
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    @State private var isEnabled: Bool

    init(item: LoginItem, onToggle: @escaping (Bool) -> Void, onDelete: @escaping () -> Void) {
        self.item = item
        self.onToggle = onToggle
        self.onDelete = onDelete
        self._isEnabled = State(initialValue: item.isEnabled)
    }

    var body: some View {
        HStack(spacing: 12) {
            // App icon placeholder
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: iconName)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let analysis = item.aiAnalysis {
                        riskBadge(analysis.riskLevel)
                    }
                }
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let analysis = item.aiAnalysis {
                    Text(analysis.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }

            Spacer()

            // Controls
            HStack(spacing: 8) {
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .accessibilityLabel("Enable \(item.name)")
                    .toggleStyle(.switch)
                    .disabled(item.type == .appService)
                    .onChange(of: item.isEnabled) { _, newValue in
                        if isEnabled != newValue {
                            isEnabled = newValue
                        }
                    }
                    .onChange(of: isEnabled) { _, newValue in
                        if newValue != item.isEnabled {
                            onToggle(newValue)
                        }
                    }

                if item.type != .appService {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete \(item.name)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch item.type {
        case .appService: return "app.badge"
        case .launchAgent: return "gear"
        case .launchDaemon: return "gearshape.2"
        }
    }

    @ViewBuilder
    private func riskBadge(_ risk: RiskLevel) -> some View {
        let (label, color): (String, Color) = switch risk {
        case .safe:        ("Safe", .green)
        case .suspicious:  ("Suspicious", .red)
        case .unknown:     ("Unknown", .yellow)
        }

        Text(label)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

#if !SWIFT_PACKAGE
#Preview {
    LoginItemsView()
        .frame(width: 700, height: 500)
}
#endif
