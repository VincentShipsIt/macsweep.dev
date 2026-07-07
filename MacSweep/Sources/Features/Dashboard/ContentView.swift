import SwiftUI
import AppKit

/// Main content view with native macOS sidebar navigation.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            ZStack {
                MacSweepDetailBackground()
                    .ignoresSafeArea()

                detailView
            }
            // Page switches are an instant swap — no slide/cross-fade chrome motion.
            // The onboarding hero still animates itself in via `ScanLandingView`'s
            // own `onAppear` rise (a local animation), so onboarding screens keep
            // their entrance while content/table pages stay still.
            .navigationTitle(appState.selectedFeature.rawValue)
        }
        .navigationSplitViewStyle(.balanced)
        // No full-window gradient: it would bleed across the sidebar and leave the
        // system's Liquid Glass nothing neutral to refract. The window background
        // and native glass chrome carry the look. GradientBackground is reserved
        // for subtle, content-only accents elsewhere.
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
        // No background overrides: the native sidebar draws its own Liquid Glass
        // material and selection highlight. Hiding the scroll background or forcing
        // it clear suppresses that material and was the cause of the broken-looking
        // selection chip.
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedFeature {
        // Main
        case .smartScan:
            DashboardView()
        case .assistant:
            AssistantView()
        case .share:
            ShareView()

        // Cleanup
        case .systemJunk:
            SystemCleanupView()
        case .mailAttachments:
            MailAttachmentsView()
        case .trashBins:
            TrashBinsView()
        case .devTools:
            DevToolsView()
        case .aiAnalysis:
            AIAnalysisView()
        case .networkCleanup:
            NetworkCleanupView()
        case .cloudCleanup:
            CloudCleanupView()

        // Protection
        case .malwareRemoval:
            MalwareScannerView()
        case .privacy:
            PrivacyView()
        case .loginItems:
            LoginItemsView()

        // Speed
        case .optimization:
            OptimizationView()
        case .batteryMonitor:
            BatteryMonitorView()
        case .maintenance:
            MaintenanceView()

        // Applications
        case .uninstaller:
            AppUninstallerView()
        case .homebrewUpdater:
            HomebrewUpdaterView()
        case .updater:
            PlaceholderFeatureView(feature: .updater)
        case .extensions:
            PlaceholderFeatureView(feature: .extensions)

        // Files
        case .spaceLens:
            SpaceLensView()
        case .largeOldFiles:
            LargeFilesView()
        case .duplicateFiles:
            DuplicateFinderView()
        case .similarPhotos:
            SimilarPhotosView()
        case .shredder:
            ShredderView()
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

// MARK: - Gradient Background

struct GradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.35, green: 0.25, blue: 0.55),  // Purple
                Color(red: 0.25, green: 0.20, blue: 0.45),  // Darker purple
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Smart Scan View (Welcome Screen)

struct SmartScanView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Assistant button (top right)
            HStack {
                Spacer()
                Button {
                    // Open assistant/help
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Assistant")
                    }
                }
                // Floating chrome control → native Liquid Glass capsule (the .glass
                // style supplies the capsule shape, padding and material itself).
                .glassButton()
            }
            .padding()

            Spacer()

            // Center content
            VStack(spacing: 32) {
                // App icon / illustration
                AppIllustration()
                    .frame(width: 280, height: 280)

                // Welcome text
                VStack(spacing: 8) {
                    Text("Welcome to MacSweep")
                        .font(.system(size: 36, weight: .bold))

                    Text("Start with a nice and thorough scan of your Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Scan button
            ScanButton(isScanning: appState.isScanning, progress: appState.scanProgress) {
                Task {
                    await appState.scan()
                }
            }
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App Illustration

struct AppIllustration: View {
    var body: some View {
        ZStack {
            // Monitor shape
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.6, blue: 0.7),
                            Color(red: 0.85, green: 0.5, blue: 0.65)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 200, height: 160)
                .offset(y: -20)

            // Stand
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.5))
                .frame(width: 80, height: 20)
                .offset(y: 80)

            // Smart Care icon
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 60))
                .foregroundStyle(.white.opacity(0.9))
                .rotationEffect(.degrees(-45))
                .offset(x: 20, y: -20)
        }
    }
}

// MARK: - Scan Button (Circular)

struct ScanButton: View {
    let isScanning: Bool
    let progress: Double
    let action: () -> Void

    @State private var isHovering = false
    @State private var pulseAnimation = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glow ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [.cyan.opacity(0.5), .blue.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 140, height: 140)
                    .scaleEffect(pulseAnimation ? 1.1 : 1.0)
                    .opacity(pulseAnimation ? 0 : 1)

                // Background circle — Liquid Glass orb (interactive: it's the tap
                // target of the primary scan action).
                Circle()
                    .fill(.clear)
                    .frame(width: 120, height: 120)
                    .glassControl(in: Circle(), interactive: true)

                // Progress ring (when scanning)
                if isScanning {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(
                                colors: [.cyan, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 120, height: 120)
                        .rotationEffect(.degrees(-90))
                }

                // Inner content
                if isScanning {
                    VStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Scan")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
            }
            .scaleEffect(isHovering ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isScanning)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: false)) {
                pulseAnimation = true
            }
        }
    }
}

// MARK: - Placeholder Feature View

struct PlaceholderFeatureView: View {
    let feature: Feature

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: feature.icon)
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            Text(feature.rawValue)
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Coming soon...")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("This feature is under development")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                .onChange(of: backgroundScanEnabled) { enabled in
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

            Link("View on GitHub", destination: URL(string: "https://github.com/VincentShipsIt/macsweep")!)
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
