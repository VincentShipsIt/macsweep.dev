import SwiftUI

/// Privacy cleanup view
struct PrivacyView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model: ScanFeatureModel
    @State private var selectedCategories: Set<String> = []
    @State private var expandedCategories: Set<String> = []

    // Quick actions state
    @State private var clearingClipboard = false
    @State private var clearingTerminal = false
    @State private var clearingRecents = false

    /// Deterministic result data for the headless snapshot harness. Production
    /// navigation uses the no-argument initializer and live scan state.
    private struct SnapshotState {
        let items: [CleanupItem]
        let hasScanned: Bool
        let errorMessage: String?
        let expandedCategories: Set<String>
    }

    private let snapshot: SnapshotState?

    init() {
        _model = StateObject(wrappedValue: FeatureScanSessions.shared.privacy)
        snapshot = nil
    }

    init(
        snapshotItems: [CleanupItem],
        snapshotHasScanned: Bool = true,
        snapshotError: String? = nil,
        snapshotExpandedCategories: Set<String>? = nil
    ) {
        _model = StateObject(wrappedValue: ScanFeatureModel())
        snapshot = SnapshotState(
            items: snapshotItems,
            hasScanned: snapshotHasScanned,
            errorMessage: snapshotError,
            expandedCategories: snapshotExpandedCategories ?? Set(snapshotItems.map(\.moduleName))
        )
    }

    var body: some View {
        FeaturePageShell(
            title: "Privacy",
            subtitle: "Remove traces of your recent activity.",
            trailing: (displayHasScanned && !displayIsScanning) ? AnyView(
                RescanButton(
                    isScanning: displayIsScanning,
                    isDisabled: !appState.hasFullDiskAccess,
                    usesNativeToolbarStyle: true
                ) {
                    Task { await scanPrivacy() }
                }
            ) : nil,
            hidesChrome: displayIsScanning || !displayHasScanned,
            scrolls: displayIsScanning || !displayHasScanned
        ) {
            Group {
                if displayIsScanning || !displayHasScanned {
                    ScanLandingView(
                        icon: "hand.raised",
                        title: "Ready to Scan",
                        description: "Find browser, app, and system traces of your recent activity that you can clear.",
                        ctaTitle: "Scan Privacy Traces",
                        benefits: [
                            ScanBenefit(
                                "eye.slash",
                                "Erases your digital footprint",
                                "Clears recent-document lists, saved app state, "
                                    + "and download history so your activity doesn't linger."
                            ),
                            ScanBenefit(
                                "checkmark.shield",
                                "You stay in control",
                                "Every trace is grouped for review, and nothing is cleared "
                                    + "until you select it and confirm."
                            )
                        ],
                        illustration: "hand.raised.fingers.spread",
                        isScanning: displayIsScanning,
                        scanningMessage: "Scanning privacy traces",
                        permissionWarning: appState.hasFullDiskAccess ? nil : .safari,
                        action: { Task { await scanPrivacy() } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scanCrossfade)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            if !appState.hasFullDiskAccess {
                                FullDiskAccessWarningBanner(scope: .safari)
                            }

                            if let displayErrorMessage {
                                MacSweepErrorBanner(message: displayErrorMessage) {
                                    model.errorMessage = nil
                                }
                            }

                            if displayItems.isEmpty {
                                noPrivacyItemsView
                            } else {
                                privacyItemsSection
                            }

                            Divider()

                            quickActionsSection
                        }
                        .padding()
                    }
                    .transition(.scanCrossfade)
                }
            }
            // Crossfade the landing ⇄ results swap (no-ops under Reduce Motion).
            .animated(.scanCrossfade, value: displayIsScanning || !displayHasScanned)
        }
        .onChange(of: appState.hasFullDiskAccess) {
            guard !appState.hasFullDiskAccess else { return }
            model.showingConfirmation = false
        }
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

                Text("\(displayItems.count) items • \(totalSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Group by category
            let grouped = Dictionary(grouping: displayItems, by: { $0.moduleName })

            ForEach(Array(grouped.keys.sorted()), id: \.self) { category in
                PrivacyCategoryCard(
                    category: category,
                    items: grouped[category] ?? [],
                    isSelected: selectedCategories.contains(category),
                    isExpanded: displayExpandedCategories.contains(category),
                    onSelectionToggle: {
                        if selectedCategories.contains(category) {
                            selectedCategories.remove(category)
                        } else {
                            selectedCategories.insert(category)
                        }
                    },
                    onExpansionToggle: {
                        if expandedCategories.contains(category) {
                            expandedCategories.remove(category)
                        } else {
                            expandedCategories.insert(category)
                        }
                    }
                )
            }

            // Clean button
            if !selectedCategories.isEmpty {
                HStack {
                    Spacer()

                    Button {
                        model.showingConfirmation = true
                    } label: {
                        Label("Clean Selected (\(selectedSize))", systemImage: "trash")
                    }
                    .glassButton(prominent: true)
                    .tint(.red)
                }
                .padding(.top)
            }
        }
        .cleanupReview(
            isPresented: $model.showingConfirmation,
            items: selectedPrivacyItems,
            disposition: .trash,
            note: "Only the selected privacy categories are moved to Trash. "
                + "Browsing data may be recreated by the relevant apps.",
            onConfirm: { await cleanSelected() }
        )
        .disabled(!appState.hasFullDiskAccess)
    }

    private var noPrivacyItemsView: some View {
        EmptyResultState(
            icon: "checkmark.shield",
            title: "No Privacy Traces Found",
            message: "Your recent activity traces look clean.",
            fillsSpace: false
        )
    }

}

// MARK: - Actions

private extension PrivacyView {
    private func scanPrivacy(requiresFullDiskAccess: Bool = true) async {
        if requiresFullDiskAccess, !appState.hasFullDiskAccess {
            model.errorMessage = FullDiskAccessScope.safari.actionBlockedMessage
            return
        }

        selectedCategories = []
        await model.scan(
            selectAllOnCompletion: false,
            onError: { "Couldn't scan for privacy traces: \($0.localizedDescription)" }
        ) {
            try await PrivacyModule().scan()
        }
    }

    private func cleanSelected() async -> CleanupResult? {
        guard appState.hasFullDiskAccess else {
            model.errorMessage = FullDiskAccessScope.safari.actionBlockedMessage
            return nil
        }

        let itemsToClean = selectedPrivacyItems

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. The aggregate DeletionGuard veto throws; per-item
        // SafetyChecker failures come back in result.errors with nothing deleted.
        let engine = ScanEngine()
        var cleanupError: String?
        var cleanupResult: CleanupResult?
        do {
            let result = try await engine.clean(items: itemsToClean, dryRun: false, confirmedLargeDeletion: true)
            cleanupResult = result
            if !result.errors.isEmpty {
                let count = result.errors.count
                cleanupError = "\(count) item\(count == 1 ? "" : "s") couldn't be cleared and were kept."
            }
        } catch {
            cleanupError = "Couldn't clear privacy items: \(error.localizedDescription)"
        }

        // Refresh (scanPrivacy clears the model error, so restore any cleanup error after)
        await scanPrivacy()
        if let cleanupError { model.errorMessage = cleanupError }
        return cleanupResult
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
            model.errorMessage = nil
        } catch {
            model.errorMessage = "Couldn't clear Terminal history: \(error.localizedDescription)"
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

        // Refresh items (scanPrivacy clears the model error, so restore after)
        await scanPrivacy(requiresFullDiskAccess: false)
        if let actionError { model.errorMessage = actionError }
    }

}

// MARK: - Computed

private extension PrivacyView {
    private var totalSize: String {
        displayItems.formattedTotalSize()
    }

    private var selectedSize: String {
        displayItems
            .filter { selectedCategories.contains($0.moduleName) }
            .formattedTotalSize()
    }

    private var selectedPrivacyItems: [CleanupItem] {
        displayItems.filter { selectedCategories.contains($0.moduleName) }
    }

    private var displayItems: [CleanupItem] {
        snapshot?.items ?? model.items
    }

    private var displayIsScanning: Bool {
        snapshot == nil && model.isScanning
    }

    private var displayHasScanned: Bool {
        snapshot?.hasScanned ?? model.hasScanned
    }

    private var displayErrorMessage: String? {
        snapshot?.errorMessage ?? model.errorMessage
    }

    private var displayExpandedCategories: Set<String> {
        snapshot?.expandedCategories ?? expandedCategories
    }
}
