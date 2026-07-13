import SwiftUI
import AppKit

/// Application delegate: owns activation-policy (dock-icon) behaviour and window
/// lifecycle observation. Kept in its own file (separate from the `@main` entry
/// point in `MacSweepApp.swift`) so it can be compiled into tooling — e.g. the
/// headless snapshot renderer — that supplies its own `@main`.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("dev.macsweep.main-window")
    private static let sharedAppState = AppState()

    private var windowObserver: Any?

    var appState: AppState { Self.sharedAppState }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Observe window visibility changes
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleWindowClose(notification)
            }
        }

    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appState.refreshFullDiskAccess()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleWindowClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }

        // Check if this is the main app window (not menu bar panel/settings).
        guard Self.isMainWindow(closedWindow) else { return }

        // After a brief delay, check if any main windows remain. Use a MainActor
        // Task (not a bare DispatchQueue closure) so the AppKit reads and the
        // @MainActor hideDockIcon() call stay inside the actor's isolation domain.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            let hasMainWindow = NSApplication.shared.windows.contains { window in
                Self.isMainWindow(window) && window.isVisible
            }

            if !hasMainWindow {
                // Hide dock icon when no main windows are open
                AppDelegate.hideDockIcon()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock re-open should recover minimized or hidden windows instead of
        // leaving the app active with no visible surface.
        _ = AppDelegate.focusMainWindow()
        return true
    }

    // MARK: - Dock Icon Management

    static func showDockIcon() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func hideDockIcon() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    @discardableResult
    static func focusMainWindow() -> Bool {
        showDockIcon()

        guard let window = NSApplication.shared.windows.first(where: { window in
            isMainWindow(window)
        }) else {
            return false
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.level == .normal &&
        window.styleMask.contains(.titled) &&
        window.identifier == mainWindowIdentifier
    }
}
