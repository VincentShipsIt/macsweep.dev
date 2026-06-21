import SwiftUI
import AppKit

/// Application delegate: owns activation-policy (dock-icon) behaviour and window
/// lifecycle observation. Kept in its own file (separate from the `@main` entry
/// point in `MacSweepApp.swift`) so it can be compiled into tooling — e.g. the
/// headless snapshot renderer — that supplies its own `@main`.
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

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
        // Dock re-open should recover minimized or hidden windows instead of
        // leaving the app active with no visible surface.
        AppDelegate.focusMainWindow()
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

        guard let window = NSApplication.shared.windows.first(where: isMainAppWindow) else {
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

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        guard window.level == .normal else { return false }
        guard window.styleMask.contains(.titled) else { return false }
        guard window.canBecomeKey || window.canBecomeMain else { return false }

        // MenuBarExtra uses its own transient window. It can look window-like to
        // AppKit, so keep focus recovery aimed at the real app surface.
        return window.frame.width >= 500 && window.frame.height >= 350
    }
}
