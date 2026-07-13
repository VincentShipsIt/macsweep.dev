import SwiftUI
import AppKit

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
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
        }

        // Menu bar widget
        MenuBarExtra {
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
        ContentView()
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

private struct MacSweepMenuBarLabel: View {
    var body: some View {
        Label("MacSweep", image: "MenuBarIcon")
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
