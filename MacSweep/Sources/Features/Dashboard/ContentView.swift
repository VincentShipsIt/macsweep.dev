import SwiftUI
import AppKit

struct MacSweepSidebarFocus {
    let isFocused: FocusState<Bool>.Binding
    let columnVisibility: Binding<NavigationSplitViewVisibility>
}

extension FocusedValues {
    @Entry var macSweepSidebarFocus: MacSweepSidebarFocus?
}

/// Main content view with native macOS sidebar navigation.
struct ContentView: View {
    var allowsInitialSidebarFocus = true
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var displayedFeature: Feature?
    @State private var usesSlideTransition = true
    @FocusState private var isSidebarFocused: Bool

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailDeck
            .clipped()
            .onAppear {
                displayedFeature = appState.selectedFeature
            }
            .onChange(of: appState.selectedFeature) { _, newFeature in
                showFeature(newFeature)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(
            \.macSweepSidebarFocus,
            MacSweepSidebarFocus(isFocused: $isSidebarFocused, columnVisibility: $columnVisibility)
        )
        // No full-window gradient: it would bleed across the sidebar and leave the
        // system's Liquid Glass nothing neutral to refract. The window background
        // and native glass chrome carry the look.
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $appState.selectedFeature) {
            ForEach(FeatureSection.allCases) { section in
                if section == .main {
                    // Smart Scan at top (no header)
                    ForEach(section.features) { feature in
                        SidebarRow(feature: feature)
                            .tag(feature)
                    }
                } else {
                    // Grouped sections
                    Section(section.rawValue) {
                        ForEach(section.features) { feature in
                            SidebarRow(feature: feature)
                                .tag(feature)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focused($isSidebarFocused)
        .defaultFocus($isSidebarFocused, allowsInitialSidebarFocus)
        .accessibilityLabel("Feature navigation")
        // No background overrides: the native sidebar draws its own Liquid Glass
        // material and selection highlight. Hiding the scroll background or forcing
        // it clear suppresses that material and was the cause of the broken-looking
        // selection chip.
    }

    // MARK: - Detail Deck

    private var activeFeature: Feature {
        displayedFeature ?? appState.selectedFeature
    }

    // SwiftUI owns the whole transition: identity is the feature itself (stable
    // across a transition, so an interrupted slide retargets instead of
    // rebuilding both pages), and insertion/removal use move transitions instead
    // of hand-scheduled offsets. Landing pages slide vertically; everything else
    // cross-fades briefly so no navigation is a hard cut.
    private var detailDeck: some View {
        ZStack {
            detailView(for: activeFeature)
                .id(activeFeature)
                .transition(
                    reduceMotion
                        ? .identity
                        : usesSlideTransition
                        ? .asymmetric(insertion: .move(edge: .bottom), removal: .move(edge: .top))
                        : .opacity
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func showFeature(_ newFeature: Feature) {
        let oldFeature = activeFeature
        guard oldFeature != newFeature else { return }

        if reduceMotion {
            usesSlideTransition = false
            displayedFeature = newFeature
            return
        }

        let shouldSlide = usesCenteredLandingTransition(oldFeature)
            && usesCenteredLandingTransition(newFeature)

        usesSlideTransition = shouldSlide
        withAnimation(shouldSlide ? .snappy(duration: 0.4) : .easeOut(duration: 0.15)) {
            displayedFeature = newFeature
        }
    }

    private func usesCenteredLandingTransition(_ feature: Feature) -> Bool {
        if feature == .systemJunk, !appState.scanResults.isEmpty {
            return false
        }
        return feature.usesCenteredLandingTransition
    }

    // MARK: - Detail View

    @ViewBuilder
    private func detailView(for feature: Feature) -> some View {
        switch feature {
        // Main
        case .smartScan:
            staticDetail(DashboardView())
        case .assistant:
            staticDetail(AssistantView())
        case .share:
            staticDetail(ShareView())
        case .cleanupHistory:
            staticDetail(CleanupHistoryView())

        // Cleanup
        case .systemJunk:
            landingDetail(SystemCleanupView(), enabled: appState.scanResults.isEmpty)
        case .mailAttachments:
            landingDetail(MailAttachmentsView())
        case .trashBins:
            landingDetail(TrashBinsView())
        case .devTools:
            landingDetail(DevToolsView())
        case .aiAnalysis:
            landingDetail(AIAnalysisView())
        case .networkCleanup:
            staticDetail(NetworkCleanupView())
        case .cloudCleanup:
            landingDetail(CloudCleanupView())

        // Protection
        case .malwareRemoval:
            landingDetail(MalwareScannerView())
        case .privacy:
            landingDetail(PrivacyView())
        case .loginItems:
            staticDetail(LoginItemsView())

        // Speed
        case .optimization:
            staticDetail(OptimizationView())
        case .batteryMonitor:
            staticDetail(BatteryMonitorView())
        case .maintenance:
            staticDetail(MaintenanceView())

        // Applications
        case .uninstaller:
            staticDetail(AppUninstallerView())
        case .homebrewUpdater:
            staticDetail(HomebrewUpdaterView())

        // Files
        case .spaceLens:
            landingDetail(SpaceLensView())
        case .largeOldFiles:
            landingDetail(LargeFilesView())
        case .duplicateFiles:
            landingDetail(DuplicateFinderView())
        case .similarPhotos:
            landingDetail(SimilarPhotosView())
        case .shredder:
            staticDetail(ShredderView())
        }
    }

    private func landingDetail<Content: View>(_ content: Content, enabled _: Bool = true) -> some View {
        content
    }

    private func staticDetail<Content: View>(_ content: Content) -> some View {
        content
    }
}

private extension Feature {
    var usesCenteredLandingTransition: Bool {
        switch self {
        case .systemJunk,
             .mailAttachments,
             .trashBins,
             .devTools,
             .aiAnalysis,
             .cloudCleanup,
             .malwareRemoval,
             .privacy,
             .spaceLens,
             .largeOldFiles,
             .duplicateFiles,
             .similarPhotos:
            return true
        case .smartScan,
             .assistant,
             .share,
             .cleanupHistory,
             .networkCleanup,
             .loginItems,
             .optimization,
             .batteryMonitor,
             .maintenance,
             .uninstaller,
             .homebrewUpdater,
             .shredder:
            return false
        }
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let feature: Feature

    var body: some View {
        // Plain Label only. The enclosing List(selection:) draws the native
        // Liquid Glass selection highlight and tints the icon for us — no custom
        // pill, no manual foreground/weight overrides to fight it.
        Label(feature.rawValue, systemImage: feature.icon)
    }
}

// MARK: - Maintenance View

struct MaintenanceView: View {
    @State private var runningTaskId: String?
    @State private var lastResult: MaintenanceResult?
    @State private var showingResult = false
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        FeaturePageShell(
            title: "Maintenance",
            subtitle: "Run upkeep tasks to keep your Mac healthy."
        ) {
            ScrollView {
                VStack(spacing: 24) {
                    // Result banner
                    if showingResult, let result = lastResult {
                        HStack {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .red)

                            Text(result.message)
                                .font(.caption)

                            Spacer()

                            Button {
                                showingResult = false
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .background(result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 40)
                    }

                    // Task list
                    VStack(spacing: 12) {
                        ForEach(MaintenanceTask.allTasks) { task in
                            MaintenanceTaskRow(
                                task: task,
                                isRunning: runningTaskId == task.id
                            ) {
                                await runTask(task)
                            }
                        }
                    }
                    .padding(.horizontal, 40)

                    Spacer(minLength: 40)
                }
                .padding(.top, 24)
            }
        }
    }

    private func runTask(_ task: MaintenanceTask) async {
        runningTaskId = task.id
        showingResult = false

        do {
            lastResult = try await task.action()
        } catch {
            lastResult = MaintenanceResult(success: false, message: error.localizedDescription)
        }

        runningTaskId = nil
        showingResult = true

        // Auto-hide after 5 seconds. Cancel any prior auto-hide first so an
        // earlier task can't fire and clear a later run's freshly shown result.
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showingResult = false
            }
        }
    }
}

struct MaintenanceTaskRow: View {
    let task: MaintenanceTask
    let isRunning: Bool
    let action: () async -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: task.icon)
                .font(.title2)
                .frame(width: 40)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(task.name)
                        .font(.headline)

                    if task.requiresAdmin {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(task.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Run") {
                    Task {
                        await action()
                    }
                }
                .glassButton()
            }
        }
        .padding()
        .macSweepCard(radius: 12)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            CompanionSettingsView()
                .tabItem {
                    Label("Companion", systemImage: "rectangle.grid.2x2")
                }

            SafetySettingsView()
                .tabItem {
                    Label("Safety", systemImage: "shield")
                }

            AssistantSettingsView()
                .tabItem {
                    Label("Assistant", systemImage: "sparkles")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 560, height: 420)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("dryRunDefault") private var dryRunDefault = true
    @AppStorage("backgroundScanEnabled") private var backgroundScanEnabled = true

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            Toggle("Dry-run by default (preview before delete)", isOn: $dryRunDefault)

            Divider()

            Toggle("Weekly background scan", isOn: $backgroundScanEnabled)
                .onChange(of: backgroundScanEnabled) { _, enabled in
                    if enabled {
                        ScanScheduler.shared.scheduleWeeklyScan()
                    } else {
                        ScanScheduler.shared.cancelScheduledScan()
                    }
                }

            if let lastScan = LastScanStore.shared.lastScan {
                Text("Last scan: \(lastScan.date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

struct CompanionSettingsView: View {
    @AppStorage(CompanionToolbarPreferences.storageCardVisible) private var storageCardVisible = true
    @AppStorage(CompanionToolbarPreferences.memoryCardVisible) private var memoryCardVisible = true
    @AppStorage(CompanionToolbarPreferences.batteryCardVisible) private var batteryCardVisible = true
    @AppStorage(CompanionToolbarPreferences.cpuCardVisible) private var cpuCardVisible = true
    @AppStorage(CompanionToolbarPreferences.networkCardVisible) private var networkCardVisible = true
    @AppStorage(CompanionToolbarPreferences.devicesCardVisible) private var devicesCardVisible = true
    @AppStorage(CompanionToolbarPreferences.smartCareCardVisible) private var smartCareCardVisible = true

    var body: some View {
        Form {
            Section("Toolbar Cards") {
                ForEach(CompanionToolbarCard.allCases) { card in
                    Toggle(isOn: binding(for: card)) {
                        Label(card.title, systemImage: card.icon)
                    }
                }
            }
        }
        .padding()
    }

    private func binding(for card: CompanionToolbarCard) -> Binding<Bool> {
        switch card {
        case .storage: return $storageCardVisible
        case .memory: return $memoryCardVisible
        case .battery: return $batteryCardVisible
        case .cpu: return $cpuCardVisible
        case .network: return $networkCardVisible
        case .devices: return $devicesCardVisible
        case .smartCare: return $smartCareCardVisible
        }
    }
}

struct SafetySettingsView: View {
    @AppStorage("maxDeleteSizeGB") private var maxDeleteSizeGB = 10.0
    @AppStorage("confirmLargeDeletes") private var confirmLargeDeletes = true

    var body: some View {
        Form {
            Slider(value: $maxDeleteSizeGB, in: 1...50, step: 1) {
                Text("Max delete size: \(Int(maxDeleteSizeGB)) GB")
            }

            Toggle("Confirm deletes over 1 GB", isOn: $confirmLargeDeletes)

            Text("Protected paths cannot be modified. MacSweep will never delete system files, credentials, or user documents.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct AssistantSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var draft = AssistantProvidersConfiguration.default
    @State private var selectedProvider: AssistantProviderKind = .codex
    @State private var statusMessage: String?
    @State private var isSaving = false

    private var assistant: AssistantCoordinator {
        appState.assistant
    }

    private var selectedEntry: AssistantProviderConfiguration {
        draft.providers[selectedProvider]
            ?? AssistantProvidersConfiguration.default.providers[selectedProvider]
            ?? AssistantProviderConfiguration(
                enabled: false,
                command: selectedProvider.rawValue,
                model: "",
                reasoningEffort: "medium"
            )
    }

    private var selectedStatus: AssistantProviderStatus? {
        assistant.providerStatuses.first { $0.provider == selectedProvider }
    }

    private var validationMessage: String? {
        guard let defaultEntry = draft.providers[draft.defaultProvider], defaultEntry.enabled else {
            return "Enable the default provider before saving."
        }

        for provider in AssistantProviderKind.allCases {
            guard let entry = draft.providers[provider], entry.enabled else { continue }
            if entry.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(provider.displayName) needs a command."
            }
            if entry.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(provider.displayName) needs a model."
            }
            if entry.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "\(provider.displayName) needs a reasoning effort."
            }
        }

        return nil
    }

    private var canSave: Bool {
        !isSaving && validationMessage == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Default provider", selection: $draft.defaultProvider) {
                    ForEach(AssistantProviderKind.allCases) { provider in
                        Text(provider.displayName)
                            .tag(provider)
                    }
                }

                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AssistantProviderKind.allCases) { provider in
                        Text(provider.displayName)
                            .tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                Divider()

                Toggle("Enabled", isOn: boolBinding(\.enabled))
                TextField("Command", text: stringBinding(\.command))
                TextField("Model", text: stringBinding(\.model))

                Picker("Reasoning", selection: stringBinding(\.reasoningEffort)) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                .pickerStyle(.segmented)

                providerStatusRow

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    NSWorkspace.shared.open(assistant.configRootURL)
                } label: {
                    Label("Config Folder", systemImage: "folder")
                }

                Spacer()

                Button("Reload") {
                    reloadDraft()
                }
                .disabled(isSaving)

                Button("Reset Defaults") {
                    draft = AssistantProvidersConfiguration.default
                    selectedProvider = draft.defaultProvider
                    statusMessage = nil
                }
                .disabled(isSaving)

                Button(isSaving ? "Saving..." : "Save") {
                    saveDraft()
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .onAppear(perform: loadDraft)
        .onChange(of: assistant.providerConfig) { _, newConfig in
            guard !isSaving else { return }
            draft = newConfig
        }
    }

    @ViewBuilder
    private var providerStatusRow: some View {
        if let selectedStatus {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Text(selectedStatus.state.rawValue.capitalized)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor(for: selectedStatus))

                    if let note = selectedStatus.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func stringBinding(
        _ keyPath: WritableKeyPath<AssistantProviderConfiguration, String>
    ) -> Binding<String> {
        Binding(
            get: {
                selectedEntry[keyPath: keyPath]
            },
            set: { newValue in
                var entry = selectedEntry
                entry[keyPath: keyPath] = newValue
                draft.providers[selectedProvider] = entry
                statusMessage = nil
            }
        )
    }

    private func boolBinding(
        _ keyPath: WritableKeyPath<AssistantProviderConfiguration, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: {
                selectedEntry[keyPath: keyPath]
            },
            set: { newValue in
                var entry = selectedEntry
                entry[keyPath: keyPath] = newValue
                draft.providers[selectedProvider] = entry
                statusMessage = nil
            }
        )
    }

    private func loadDraft() {
        draft = assistant.providerConfig
        selectedProvider = draft.defaultProvider
        statusMessage = nil
    }

    private func reloadDraft() {
        Task { @MainActor in
            await assistant.reload()
            loadDraft()
            statusMessage = "Assistant provider settings reloaded."
        }
    }

    private func saveDraft() {
        Task { @MainActor in
            isSaving = true
            let saved = await assistant.saveProviderConfiguration(normalizedDraft())
            isSaving = false

            if saved {
                draft = assistant.providerConfig
                statusMessage = "Assistant provider settings saved."
            } else {
                statusMessage = assistant.lastError ?? "Assistant provider settings could not be saved."
            }
        }
    }

    private func normalizedDraft() -> AssistantProvidersConfiguration {
        var normalized = draft
        normalized.fallbackOrder = [normalized.defaultProvider]
            + normalized.fallbackOrder.filter { $0 != normalized.defaultProvider }

        for provider in AssistantProviderKind.allCases {
            guard var entry = normalized.providers[provider] else { continue }
            entry.command = entry.command.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.model = entry.model.trimmingCharacters(in: .whitespacesAndNewlines)
            entry.reasoningEffort = entry.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            normalized.providers[provider] = entry
        }

        return normalized
    }

    private func statusColor(for status: AssistantProviderStatus) -> Color {
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
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 64))
                .foregroundStyle(.purple)

            Text("MacSweep")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? MacSweepVersion.current)")
                .foregroundStyle(.secondary)

            Text("Open-source macOS system cleaner")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link("MacSweep website", destination: URL(string: "https://macsweep.dev")!)

                Divider()
                    .frame(height: 12)

                Link("View on GitHub", destination: URL(string: "https://github.com/VincentShipsIt/macsweep")!)
            }
                .font(.caption)
        }
        .padding()
    }
}

#if !SWIFT_PACKAGE
#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 900, height: 600)
}

#endif
