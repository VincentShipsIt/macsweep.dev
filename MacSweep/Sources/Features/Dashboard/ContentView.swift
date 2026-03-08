import SwiftUI

/// Main content view with CleanMyMac-style sidebar navigation
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .background(GradientBackground())
    }

    // MARK: - Sidebar (CleanMyMac style)

    private var sidebar: some View {
        List(selection: $appState.selectedFeature) {
            ForEach(FeatureSection.allCases) { section in
                if section == .main {
                    // Smart Scan at top (no header)
                    ForEach(section.features) { feature in
                        SidebarRow(feature: feature, isSelected: appState.selectedFeature == feature)
                            .tag(feature)
                    }
                } else {
                    // Grouped sections
                    Section(section.rawValue) {
                        ForEach(section.features) { feature in
                            SidebarRow(feature: feature, isSelected: appState.selectedFeature == feature)
                                .tag(feature)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedFeature {
        // Main
        case .smartScan:
            SmartScanView()

        // Cleanup
        case .systemJunk:
            SystemCleanupView()
        case .mailAttachments:
            MailAttachmentsView()
        case .trashBins:
            TrashBinsView()
        case .devTools:
            DevToolsView()
        case .networkCleanup:
            NetworkCleanupView()

        // Protection
        case .malwareRemoval:
            PlaceholderFeatureView(feature: .malwareRemoval)
        case .privacy:
            PrivacyView()

        // Speed
        case .optimization:
            OptimizationView()
        case .maintenance:
            MaintenanceView()

        // Applications
        case .uninstaller:
            AppUninstallerView()
        case .updater:
            PlaceholderFeatureView(feature: .updater)
        case .extensions:
            PlaceholderFeatureView(feature: .extensions)

        // Files
        case .spaceLens:
            SpaceLensView()
        case .largeOldFiles:
            LargeFilesView()
        case .shredder:
            ShredderView()
        }
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let feature: Feature
    let isSelected: Bool

    var body: some View {
        Label {
            Text(feature.rawValue)
                .fontWeight(isSelected ? .semibold : .regular)
        } icon: {
            Image(systemName: feature.icon)
                .foregroundStyle(isSelected ? .white : .secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isSelected ?
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.8))
                : nil
        )
        .foregroundStyle(isSelected ? .white : .primary)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
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

            // Broom icon
            Image(systemName: "paintbrush.pointed")
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

                // Background circle
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 120, height: 120)

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

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)

                    Text("Maintenance")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Run maintenance tasks to keep your Mac running smoothly")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

        // Auto-hide after 5 seconds
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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
                .buttonStyle(.bordered)
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

            SafetySettingsView()
                .tabItem {
                    Label("Safety", systemImage: "shield")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
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

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 64))
                .foregroundStyle(.purple)

            Text("MacSweep")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
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

#Preview {
    ContentView()
        .environmentObject(AppState())
        .frame(width: 900, height: 600)
}
