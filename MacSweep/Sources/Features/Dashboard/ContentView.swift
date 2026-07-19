import SwiftUI
import AppKit
import ServiceManagement

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
    @AppStorage(DeveloperModePreferences.enabledKey) private var developerModeEnabled = false
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
        .onChange(of: developerModeEnabled) { _, enabled in
            if !enabled, appState.selectedFeature == .developerLogs {
                appState.selectedFeature = .smartScan
            }
        }
        // No full-window gradient: it would bleed across the sidebar and leave the
        // system's Liquid Glass nothing neutral to refract. The window background
        // and native glass chrome carry the look.
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $appState.selectedFeature) {
            ForEach(visibleSections) { section in
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

    private var visibleSections: [FeatureSection] {
        developerModeEnabled
            ? FeatureSection.allCases
            : FeatureSection.allCases.filter { $0 != .developer }
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
        // A GeometryReader has zero minimum size and simply reports the space the
        // split view offers. Sizing the detail to that (rather than letting the
        // content size the deck) stops a page whose content is a `List` — e.g.
        // Smart Care — from reporting its full content height as the window's
        // minimum, which previously pinned the whole window ~1500pt tall. The List
        // now scrolls inside the available height like every ScrollView page does.
        GeometryReader { proxy in
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
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
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

        // Developer
        case .developerLogs:
            staticDetail(DeveloperLogsView())
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
             .shredder,
             .developerLogs:
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

// MARK: - Settings View

struct SettingsView: View {
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

            DeveloperSettingsView()
                .tabItem {
                    Label("Developer", systemImage: "hammer")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 720, height: 620)
    }
}

struct GeneralSettingsView: View {
    // SMAppService is the source of truth for login-item state; the toggle
    // mirrors it rather than persisting a parallel flag in defaults.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var backgroundScanIntervalDays = SchedulerConfig().intervalDays
    @AppStorage(MenuBarPreferences.iconVisibleKey) private var showMenuBarIcon = true
    @AppStorage(ScanScheduler.enabledDefaultsKey) private var backgroundScanEnabled = true
    @AppStorage(UpdateChannel.defaultsKey) private var updateChannelRaw = UpdateChannel.resolved().rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Registration fails outside a proper app bundle
                            // (e.g. `swift run`); reflect the real state.
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            }

            Section {
                Toggle("Background scans", isOn: $backgroundScanEnabled)
                    .onChange(of: backgroundScanEnabled) { _, enabled in
                        if enabled {
                            ScanScheduler.shared.scheduleNextScan()
                        } else {
                            ScanScheduler.shared.cancelScheduledScan()
                        }
                    }

                Stepper(
                    value: $backgroundScanIntervalDays,
                    in: SchedulerConfig.minIntervalDays...SchedulerConfig.maxIntervalDays
                ) {
                    LabeledContent("Scan interval") {
                        Text(
                            "\(backgroundScanIntervalDays) "
                                + (backgroundScanIntervalDays == 1 ? "day" : "days")
                        )
                    }
                }
                .onChange(of: backgroundScanIntervalDays) { _, days in
                    ScanScheduler.shared.updateIntervalDays(days)
                }

                if let lastScan = LastScanStore.shared.lastScan {
                    LabeledContent("Last scan") {
                        Text(lastScan.date.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(
                    "Background scans run while MacSweep is open. "
                        + "Changing the interval schedules the next scan from now when enabled."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Update channel", selection: $updateChannelRaw) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel.rawValue)
                    }
                }
            } footer: {
                Text("Nightly builds are signed and notarized from the latest master commit, but less tested than stable releases. The choice applies on the next update check (MacSweep ▸ Check for Updates…). Switching back to Stable keeps the installed build until the next stable release ships.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        .formStyle(.grouped)
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
    @AppStorage(DeletionGuard.maxDeleteSizeGBKey) private var maxDeleteSizeGB = DeletionGuard.defaultMaxDeleteSizeGB
    @State private var selectedRuleKind = UserProtectionRuleKind.ignore
    @State private var ignoreDocument = UserProtectionRuleDocument.empty(
        kind: .ignore,
        homeURL: FileManager.default.homeDirectoryForCurrentUser
    )
    @State private var protectDocument = UserProtectionRuleDocument.empty(
        kind: .protect,
        homeURL: FileManager.default.homeDirectoryForCurrentUser
    )
    @State private var ignoreEntries: [UserProtectionRuleDocument.Entry] = []
    @State private var protectEntries: [UserProtectionRuleDocument.Entry] = []
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    private let ruleStore = UserProtectionRuleStore()

    private var selectedEntries: Binding<[UserProtectionRuleDocument.Entry]> {
        switch selectedRuleKind {
        case .ignore: $ignoreEntries
        case .protect: $protectEntries
        }
    }

    private var selectedDocument: UserProtectionRuleDocument {
        switch selectedRuleKind {
        case .ignore: ignoreDocument
        case .protect: protectDocument
        }
    }

    private var selectedValidationMessage: String? {
        selectedEntries.wrappedValue.compactMap {
            UserProtectionRuleDocument.validationMessage(for: $0)
        }.first
    }

    var body: some View {
        Form {
            Section {
                Slider(value: $maxDeleteSizeGB, in: 1...50, step: 1) {
                    Text("Max delete size: \(Int(maxDeleteSizeGB)) GB")
                }
                LabeledContent("Current aggregate cap") {
                    Text("\(Int(maxDeleteSizeGB)) GB per cleanup")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Deletion limit")
            } footer: {
                Text(
                    "MacSweep re-measures selected paths immediately before deletion "
                        + "and blocks the whole cleanup when the live total exceeds this cap."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Rule file", selection: $selectedRuleKind) {
                    ForEach(UserProtectionRuleKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Backing file") {
                    Text(selectedDocument.fileURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(selectedRuleKind.behaviorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProtectionRuleEditor(
                    entries: selectedEntries,
                    kind: selectedRuleKind
                )

                HStack {
                    Button {
                        selectedEntries.wrappedValue.append(
                            UserProtectionRuleDocument.Entry(pattern: "")
                        )
                        savedMessage = nil
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }

                    Spacer()

                    Button("Reload") {
                        loadRuleFile(selectedRuleKind)
                    }

                    Button("Save File") {
                        saveSelectedRuleFile()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedValidationMessage != nil)
                }

                if let selectedValidationMessage {
                    Label(selectedValidationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let errorMessage {
                    MacSweepErrorBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                } else if let savedMessage {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            } header: {
                Text("User path rules")
            } footer: {
                Text(
                    "Rules accept absolute paths, ~/ paths, home-relative paths, *, ** and ?. "
                        + "Enable Exception to cancel an earlier user rule. "
                        + "Comments and blank lines in each file are preserved."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Safety defaults") {
                SafetyDefaultRow(
                    icon: "trash",
                    title: "Trash first",
                    detail: "Review-oriented cleanup moves user data to Trash so it can be recovered."
                )
                SafetyDefaultRow(
                    icon: "exclamationmark.shield",
                    title: "Permanent-delete exceptions",
                    detail: "Regenerable caches, browser and privacy data, Empty Trash, "
                        + "and secure shredding are permanent after confirmation."
                )
                SafetyDefaultRow(
                    icon: "lock.shield",
                    title: "Built-in protected paths",
                    detail: "System roots, credentials, cloud data, and user document roots "
                        + "remain blocked even when a user rule contains an exception."
                )
                SafetyDefaultRow(
                    icon: "gauge.with.dots.needle.67percent",
                    title: "Aggregate deletion cap",
                    detail: "A single cleanup above \(Int(maxDeleteSizeGB)) GB is blocked "
                        + "instead of partially deleting the selection."
                )
            }
        }
        .formStyle(.grouped)
        .task {
            loadRuleFiles()
        }
        .onChange(of: selectedRuleKind) {
            errorMessage = nil
            savedMessage = nil
        }
    }

    private func loadRuleFiles() {
        var failures: [String] = []
        for kind in UserProtectionRuleKind.allCases {
            if let failure = loadRuleFile(kind, updatesMessage: false) {
                failures.append(failure)
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: " ")
        savedMessage = nil
    }

    @discardableResult
    private func loadRuleFile(
        _ kind: UserProtectionRuleKind,
        updatesMessage: Bool = true
    ) -> String? {
        do {
            let document = try ruleStore.load(kind)
            switch kind {
            case .ignore:
                ignoreDocument = document
                ignoreEntries = document.entries
            case .protect:
                protectDocument = document
                protectEntries = document.entries
            }
            if updatesMessage {
                errorMessage = nil
                savedMessage = nil
            }
            return nil
        } catch {
            let message = Self.actionableMessage(for: error)
            if updatesMessage {
                errorMessage = message
                savedMessage = nil
            }
            return message
        }
    }

    private func saveSelectedRuleFile() {
        do {
            var document = selectedDocument
            try document.replaceEntries(selectedEntries.wrappedValue)
            try ruleStore.save(document)

            switch selectedRuleKind {
            case .ignore:
                ignoreDocument = document
                ignoreEntries = document.entries
            case .protect:
                protectDocument = document
                protectEntries = document.entries
            }
            errorMessage = nil
            savedMessage = "Saved \(document.fileURL.lastPathComponent) atomically."
        } catch {
            errorMessage = Self.actionableMessage(for: error)
            savedMessage = nil
        }
    }

    private static func actionableMessage(for error: Error) -> String {
        let description = error.localizedDescription
        guard let recovery = (error as? LocalizedError)?.recoverySuggestion else {
            return description
        }
        return "\(description) \(recovery)"
    }
}

private struct ProtectionRuleEditor: View {
    @Binding var entries: [UserProtectionRuleDocument.Entry]
    let kind: UserProtectionRuleKind

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("No \(kind.title.lowercased())", systemImage: "doc.text")
            } description: {
                Text("The backing file has no active rules.")
            }
            .frame(minHeight: 90)
        } else {
            VStack(spacing: 8) {
                ForEach($entries) { $entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle("Exception", isOn: $entry.isException)
                                .toggleStyle(.checkbox)
                                .help("Cancel an earlier matching rule in this file")

                            TextField("Path or glob", text: $entry.pattern)
                                .font(.body.monospaced())

                            Button(role: .destructive) {
                                entries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove rule")
                        }

                        if let validationMessage = UserProtectionRuleDocument.validationMessage(for: entry) {
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SafetyDefaultRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DeveloperSettingsView: View {
    @AppStorage(DeveloperModePreferences.enabledKey) private var developerModeEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle("Developer mode", isOn: $developerModeEnabled)
            } footer: {
                Text(
                    "Shows the Developer section and its local Logs page. "
                        + "Deletion auditing stays active even when Developer mode is off."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Logging") {
                LabeledContent("Retention", value: "5,000 events or 180 days")
                LabeledContent("Storage", value: "On this Mac only")
            }
        }
        .formStyle(.grouped)
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
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Default provider", selection: $draft.defaultProvider) {
                        ForEach(AssistantProviderKind.allCases) { provider in
                            Text(provider.displayName)
                                .tag(provider)
                        }
                    }
                }

                Section {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(AssistantProviderKind.allCases) { provider in
                            Text(provider.displayName)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

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
                } footer: {
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button {
                    NSWorkspace.shared.open(assistant.configRootURL)
                } label: {
                    Label("Config Folder", systemImage: "folder")
                }
                .glassButton()

                Spacer()

                Button("Reload") {
                    reloadDraft()
                }
                .glassButton()
                .disabled(isSaving)

                Button("Reset Defaults") {
                    draft = AssistantProvidersConfiguration.default
                    selectedProvider = draft.defaultProvider
                    statusMessage = nil
                }
                .glassButton()
                .disabled(isSaving)

                Button(isSaving ? "Saving..." : "Save") {
                    saveDraft()
                }
                .glassButton(prominent: true)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom])
            .padding(.top, 8)
        }
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
