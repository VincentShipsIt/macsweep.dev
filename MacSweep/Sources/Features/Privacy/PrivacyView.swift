import SwiftUI

/// Privacy cleanup view
struct PrivacyView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var privacyItems: [CleanupItem] = []
    @State private var selectedCategories: Set<String> = []
    @State private var showingConfirmation = false

    // Quick actions state
    @State private var clearingClipboard = false
    @State private var clearingTerminal = false
    @State private var clearingRecents = false
    @State private var errorMessage: String?

    var body: some View {
        FeaturePageShell(
            title: "Privacy",
            subtitle: "Remove traces of your recent activity.",
            trailing: privacyItems.isEmpty ? nil : AnyView(
                Button {
                    Task { await scanPrivacy() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(isScanning)
            )
        ) {
            ScrollView {
                VStack(spacing: 24) {
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }

                    // Quick Actions (always visible)
                    quickActionsSection

                    Divider()
                        .overlay(MacSweepTheme.divider)

                    // Privacy Items (scan-driven)
                    if privacyItems.isEmpty {
                        ScanLandingView(
                            icon: "hand.raised",
                            title: "Scan for Privacy Traces",
                            description: "Find browser, app, and system traces of your recent activity that you can clear.",
                            ctaTitle: "Scan Privacy Traces",
                            benefits: [
                                ScanBenefit("eye.slash", "Erases your digital footprint", "Clears recent-document lists, saved app state, and download history so your activity doesn't linger."),
                                ScanBenefit("checkmark.shield", "You stay in control", "Every trace is grouped for review, and nothing is cleared until you select it and confirm."),
                            ],
                            illustration: "hand.raised.fingers.spread",
                            isScanning: isScanning,
                            action: { Task { await scanPrivacy() } }
                        )
                    } else {
                        privacyItemsSection
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.caption)
            Spacer()
            Button { errorMessage = nil } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Quick Actions

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                QuickActionCard(
                    title: "Clear Clipboard",
                    icon: "doc.on.clipboard",
                    color: .blue,
                    isLoading: clearingClipboard
                ) {
                    clearClipboard()
                }

                QuickActionCard(
                    title: "Clear Terminal History",
                    icon: "terminal",
                    color: .green,
                    isLoading: clearingTerminal
                ) {
                    await clearTerminalHistory()
                }

                QuickActionCard(
                    title: "Clear Recent Documents",
                    icon: "doc.text",
                    color: .orange,
                    isLoading: clearingRecents
                ) {
                    await clearRecentDocuments()
                }
            }
        }
    }

    // MARK: - Privacy Items Section

    private var privacyItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Privacy Items")
                    .font(.headline)

                Spacer()

                Text("\(privacyItems.count) items • \(totalSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Group by category
            let grouped = Dictionary(grouping: privacyItems, by: { $0.moduleName })

            ForEach(Array(grouped.keys.sorted()), id: \.self) { category in
                PrivacyCategoryCard(
                    category: category,
                    items: grouped[category] ?? [],
                    isSelected: selectedCategories.contains(category),
                    onToggle: {
                        if selectedCategories.contains(category) {
                            selectedCategories.remove(category)
                        } else {
                            selectedCategories.insert(category)
                        }
                    }
                )
            }

            // Clean button
            if !selectedCategories.isEmpty {
                HStack {
                    Spacer()

                    Button {
                        showingConfirmation = true
                    } label: {
                        Label("Clean Selected (\(selectedSize))", systemImage: "trash")
                    }
                    .glassButton(prominent: true)
                    .tint(.red)
                }
                .padding(.top)
            }
        }
        .confirmationDialog(
            "Clear Privacy Items?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Selected", role: .destructive) {
                Task {
                    await cleanSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove \(selectedSize) of privacy data. This cannot be undone.")
        }
    }

    // MARK: - Actions

    private func scanPrivacy() async {
        isScanning = true
        privacyItems = []
        selectedCategories = []
        errorMessage = nil

        defer { isScanning = false }

        let module = PrivacyModule()
        do {
            privacyItems = try await module.scan()
        } catch {
            errorMessage = "Couldn't scan for privacy traces: \(error.localizedDescription)"
        }
    }

    private func cleanSelected() async {
        let itemsToClean = privacyItems.filter { selectedCategories.contains($0.moduleName) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. The aggregate DeletionGuard veto throws; per-item
        // SafetyChecker failures come back in result.errors with nothing deleted.
        let engine = ScanEngine()
        var cleanupError: String?
        do {
            let result = try await engine.clean(items: itemsToClean, dryRun: false)
            if !result.errors.isEmpty {
                let count = result.errors.count
                cleanupError = "\(count) item\(count == 1 ? "" : "s") couldn't be cleared and were kept."
            }
        } catch {
            cleanupError = "Couldn't clear privacy items: \(error.localizedDescription)"
        }

        // Refresh (scanPrivacy clears errorMessage, so restore any cleanup error after)
        await scanPrivacy()
        if let cleanupError { errorMessage = cleanupError }
    }

    private func clearClipboard() {
        clearingClipboard = true
        PrivacyActions.clearClipboard()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            clearingClipboard = false
        }
    }

    private func clearTerminalHistory() async {
        clearingTerminal = true
        do {
            try await PrivacyActions.clearTerminalHistory()
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't clear Terminal history: \(error.localizedDescription)"
        }

        await MainActor.run {
            clearingTerminal = false
        }
    }

    private func clearRecentDocuments() async {
        clearingRecents = true
        var actionError: String?
        do {
            try await PrivacyActions.clearRecentDocuments()
        } catch {
            actionError = "Couldn't clear recent documents: \(error.localizedDescription)"
        }

        await MainActor.run {
            clearingRecents = false
        }

        // Refresh items (scanPrivacy clears errorMessage, so restore after)
        await scanPrivacy()
        if let actionError { errorMessage = actionError }
    }

    // MARK: - Computed

    private var totalSize: String {
        let total = privacyItems.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var selectedSize: String {
        let total = privacyItems
            .filter { selectedCategories.contains($0.moduleName) }
            .reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Quick Action Card

struct QuickActionCard: View {
    let title: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task {
                await action()
            }
        } label: {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(color)
                }

                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

// MARK: - Privacy Category Card

struct PrivacyCategoryCard: View {
    let category: String
    let items: [CleanupItem]
    let isSelected: Bool
    let onToggle: () -> Void

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    private var icon: String {
        if category.contains("Recent Documents") { return "doc.text" }
        if category.contains("Recent Applications") { return "app.badge" }
        if category.contains("Saved State") { return "square.stack.3d.up" }
        if category.contains("Download") || category.contains("Quarantine") { return "arrow.down.circle" }
        if category.contains("Server") { return "server.rack" }
        if category.contains("Host") { return "network" }
        return "hand.raised"
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 16) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title2)

                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.purple)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category)
                        .font(.headline)

                    Text("\(items.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    PrivacyView()
        .environmentObject(AppState())
        .frame(width: 600, height: 700)
}

#endif
