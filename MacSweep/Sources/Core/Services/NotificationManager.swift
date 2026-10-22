import Foundation
import UserNotifications

protocol ScanNotificationCenter: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping (Bool, Error?) -> Void)
    func add(_ request: UNNotificationRequest)
}

final class SystemScanNotificationCenter: ScanNotificationCenter {
    private let center: UNUserNotificationCenter
    init(center: UNUserNotificationCenter = .current()) { self.center = center }
    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }
    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping (Bool, Error?) -> Void) {
        center.requestAuthorization(options: options, completionHandler: completion)
    }
    func add(_ request: UNNotificationRequest) { center.add(request) }
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager(center: SystemScanNotificationCenter())
    var openApplication: () -> Void
    private let center: any ScanNotificationCenter
    private let now: () -> Date

    init(
        center: any ScanNotificationCenter, now: @escaping () -> Date = { Date() },
        openApplication: @escaping () -> Void = {}
    ) {
        self.center = center
        self.now = now
        self.openApplication = openApplication
        super.init()
        center.delegate = self
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sendScanComplete(bytesFound: Int64) {
        let content = UNMutableNotificationContent()
        content.title = ScanNotificationContent.title
        content.body = ScanNotificationContent.formattedBody(for: bytesFound)
        content.sound = .default
        content.categoryIdentifier = ScanNotificationContent.categoryIdentifier
        let request = UNNotificationRequest(
            identifier: "weekly-scan-\(now().timeIntervalSince1970)",
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleOpen(completionHandler: completionHandler)
    }

    nonisolated func handleOpen(completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.openApplication() }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) { completionHandler(Self.foregroundPresentation) }

    nonisolated static var foregroundPresentation: UNNotificationPresentationOptions { [.banner, .sound] }
}
