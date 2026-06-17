import SwiftUI
import AppKit

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false

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
            Label("MacSweep", systemImage: appState.menuBarIcon)
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
