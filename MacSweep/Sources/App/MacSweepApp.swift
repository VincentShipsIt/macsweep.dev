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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as accessory (menu bar only, no dock icon)
        NSApplication.shared.setActivationPolicy(.accessory)

        // Observe window visibility changes
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWindowClose(notification)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleWindowClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }

        // Check if this is a main window (not menu bar panel)
        guard closedWindow.level == .normal,
              closedWindow.styleMask.contains(.titled) else { return }

        // After a brief delay, check if any main windows remain
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let hasMainWindow = NSApplication.shared.windows.contains { window in
                window.level == .normal &&
                window.styleMask.contains(.titled) &&
                window.isVisible
            }

            if !hasMainWindow {
                // Hide dock icon when no main windows are open
                AppDelegate.hideDockIcon()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // When clicking dock icon, keep it visible
        return true
    }

    // MARK: - Dock Icon Management

    static func showDockIcon() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func hideDockIcon() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
