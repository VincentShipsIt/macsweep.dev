import UserNotifications
import Foundation
import AppKit

class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        // Set the delegate eagerly, not inside the authorization callback. The
        // delegate drives tap-handling and foreground presentation; wiring it
        // only on `granted` meant a notification scheduled before the prompt was
        // answered (or on a previously-authorized launch where requestPermission
        // wasn't called this run) would never route through us.
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    func sendScanComplete(bytesFound: Int64) {
        let content = UNMutableNotificationContent()
        // Wording/thresholds live in MacSweepCore (ScanCompleteNotification) so
        // they are covered by swift test; this class only does UN plumbing.
        content.title = ScanCompleteNotification.title
        content.body = ScanCompleteNotification.body(bytesFound: bytesFound)
        content.sound = .default
        content.categoryIdentifier = ScanCompleteNotification.categoryIdentifier

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "weekly-scan-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request)
    }

    // Handle tap on notification — open MacSweep
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // UNUserNotificationCenterDelegate delivery is not documented as
        // main-thread on macOS, so hop to the main actor before touching AppKit.
        // completionHandler() stays outside the Task so the system gets it promptly.
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            // Open main window
            NSApp.windows.first(where: { $0.level == .normal })?.makeKeyAndOrderFront(nil)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
