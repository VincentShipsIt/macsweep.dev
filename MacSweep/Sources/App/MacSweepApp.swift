import SwiftUI
import AppKit

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false

    var body: some Scene {
        // Menu bar widget
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Label("MacSweep", systemImage: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        // Main window with ID for programmatic opening
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .sheet(isPresented: $showingOnboarding) {
                    OnboardingView(isPresented: $showingOnboarding)
                }
                .onAppear {
                    if !hasCompletedOnboarding {
                        showingOnboarding = true
                    }
                    // Show dock icon when main window appears
                    AppDelegate.showDockIcon()
                }
                .task {
                    // Register and schedule weekly background scan
                    ScanScheduler.shared.register()
                    NotificationManager.shared.requestPermission()
                }
                .onChange(of: showingOnboarding) { newValue in
                    if !newValue {
                        hasCompletedOnboarding = true
                    }
                }
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
