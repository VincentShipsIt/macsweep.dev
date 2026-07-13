import SwiftUI
import AppKit

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(MenuBarPreferences.iconVisibleKey) private var showMenuBarIcon = true
    @State private var showingOnboarding = false

    /// App-global run-once guard for lifecycle side effects.
    @MainActor private static var didRunLaunchSideEffects = false
    private static let mainWindowLaunchSize = CGSize(width: 1040, height: 800)

    var body: some Scene {
        Window("MacSweep", id: "main") {
            mainWindowContent
        }
        .defaultSize(width: Self.mainWindowLaunchSize.width, height: Self.mainWindowLaunchSize.height)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            MacSweepCommands(appState: appDelegate.appState)
        }

        // Menu bar widget
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        } label: {
            MacSweepMenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }

    private var mainWindowContent: some View {
        ContentView(allowsInitialSidebarFocus: hasCompletedOnboarding && !showingOnboarding)
            .environmentObject(appDelegate.appState)
            .background(MainWindowIdentifierAccessor())
            // Open compact and centered every launch (CleanMyMac-style), instead of
            // restoring whatever — often full-height — frame the window was last
            // dragged to.
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView(isPresented: $showingOnboarding)
            }
            .onAppear {
                if !hasCompletedOnboarding {
                    showingOnboarding = true
                }
                AppDelegate.showDockIcon()
            }
            .task {
                // Run only once per app launch, even if a second window
                // instantiates this content (reopening the closed main window).
                guard !Self.didRunLaunchSideEffects else { return }
                Self.didRunLaunchSideEffects = true

                #if DEBUG
                // Debug relaunches must be passive. Registering the scheduler can
                // immediately run an overdue full scan, which touches Desktop and
                // other TCC-protected folders before the developer clicks anything.
                return
                #else
                ScanScheduler.shared.register()
                NotificationManager.shared.requestPermission()
                #endif
            }
            .onChange(of: showingOnboarding) { _, newValue in
                if !newValue {
                    hasCompletedOnboarding = true
                }
            }
    }
}

private struct MacSweepCommands: Commands {
    @ObservedObject var appState: AppState
    @FocusedValue(\.macSweepSidebarFocus) private var sidebarFocus

    var body: some Commands {
        CommandMenu("Scan") {
            Button("Start Smart Care Scan") {
                Task { await appState.quickScan() }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(appState.isScanning)

            Button("Stop Scan") {
                appState.cancelScan()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!appState.isScanning)
        }

        CommandMenu("Navigate") {
            Button("Focus Sidebar") {
                guard let sidebarFocus else { return }

                sidebarFocus.columnVisibility.wrappedValue = .all
                // Let the split view restore the sidebar before assigning focus.
                DispatchQueue.main.async {
                    sidebarFocus.isFocused.wrappedValue = true
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(sidebarFocus == nil)

            Divider()

            Button("Smart Care") {
                appState.selectedFeature = .smartScan
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Assistant") {
                appState.selectedFeature = .assistant
            }
            .keyboardShortcut("2", modifiers: .command)
        }
    }
}

private struct MacSweepMenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("MacSweep", image: "MenuBarIcon")
            .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openMainWindowRequest)) { _ in
                AppDelegate.openMainWindowIfNeeded {
                    openWindow(id: "main")
                }
            }
    }
}

private struct MainWindowIdentifierAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { tagWindow(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { tagWindow(for: nsView) }
    }

    private func tagWindow(for view: NSView) {
        view.window?.identifier = AppDelegate.mainWindowIdentifier
    }
}
