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
    private static let mainWindowLaunchSize = CGSize(width: 1040, height: 800)

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

            // Stop AppKit/SwiftUI from restoring a remembered frame over ours.
            window.isRestorable = false
            window.setContentSize(size)
            window.center()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
