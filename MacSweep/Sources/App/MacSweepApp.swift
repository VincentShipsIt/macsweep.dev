import SwiftUI
import AppKit

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false

    /// App-global run-once guard for lifecycle side effects (scheduler
    /// registration, notification permission). Static rather than `@State`
    /// because there are two `WindowGroup`s rendering `mainWindowContent`, and
    /// reopening the main window instantiates a fresh view with its own `@State`
    /// — a static flag dedupes across every window instance, not just one.
    @MainActor private static var didRunLaunchSideEffects = false

    var body: some Scene {
        // Default launch window.
        WindowGroup {
            mainWindowContent
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Main window with ID for programmatic opening from the menu bar extra.
        WindowGroup(id: "main") {
            mainWindowContent
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu bar widget
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("MacSweep", image: "MenuBarIcon")
        }
        .menuBarExtraStyle(.window)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }

    private var mainWindowContent: some View {
        ContentView()
            .environmentObject(appState)
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
                ScanScheduler.shared.register()
                NotificationManager.shared.requestPermission()
            }
            .onChange(of: showingOnboarding) { newValue in
                if !newValue {
                    hasCompletedOnboarding = true
                }
            }
    }
}
