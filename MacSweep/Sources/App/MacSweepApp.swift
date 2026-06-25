import SwiftUI
import AppKit

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showingOnboarding = false

    /// App-global run-once guard for lifecycle side effects (scheduler
    /// registration, notification permission). Static rather than `@State`
    /// because there are two `WindowGroup`s rendering `mainWindowContent`, and
    /// reopening the main window instantiates a fresh view with its own `@State`
    /// — a static flag dedupes across every window instance, not just one.
    @MainActor private static var didRunLaunchSideEffects = false
    private static let mainWindowLaunchSize = CGSize(width: 1040, height: 800)

    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                _ = AppDelegate.openMainWindowIfNeeded()
            }
        }
    }

    var body: some Scene {
        // Default launch window.
        WindowGroup {
            mainWindowContent
        }
        .defaultSize(width: Self.mainWindowLaunchSize.width, height: Self.mainWindowLaunchSize.height)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Main window with ID for programmatic opening from the menu bar extra.
        WindowGroup(id: "main") {
            mainWindowContent
        }
        .defaultSize(width: Self.mainWindowLaunchSize.width, height: Self.mainWindowLaunchSize.height)
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
            // Open compact and centered every launch (CleanMyMac-style), instead of
            // restoring whatever — often full-height — frame the window was last
            // dragged to.
            .background(MainWindowChromeConfigurator(size: Self.mainWindowLaunchSize))
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
            .onChange(of: showingOnboarding) { newValue in
                if !newValue {
                    hasCompletedOnboarding = true
                }
            }
    }
}

private struct MacSweepMenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @State private var didRequestInitialWindow = false

    var body: some View {
        Label("MacSweep", image: "MenuBarIcon")
            .task {
                guard !didRequestInitialWindow else { return }
                didRequestInitialWindow = true

                try? await Task.sleep(nanoseconds: 700_000_000)
                await MainActor.run {
                    guard !AppDelegate.focusMainWindow() else { return }
                    openWindow(id: "main")
                }

                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run {
                    _ = AppDelegate.focusMainWindow()
                }
            }
    }
}

/// Configures the host window's native sidebar/titlebar chrome and launch size.
/// Runs once per window instantiation: users can resize during the session, and
/// the next launch reopens compact while preserving the native full-height
/// sidebar look.
private struct MainWindowChromeConfigurator: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.isOpaque = false
            window.backgroundColor = .clear

            // Stop AppKit/SwiftUI from restoring a remembered frame over ours.
            window.isRestorable = false
            window.setContentSize(size)
            window.center()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
