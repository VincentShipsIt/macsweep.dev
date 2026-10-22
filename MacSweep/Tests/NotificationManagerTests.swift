import Foundation
import Testing
import UserNotifications

@testable import MacSweepCore

@MainActor
struct NotificationManagerTests {
    @Test func delegateIsRegisteredBeforePermissionOrDelivery() {
        let center = FixtureNotificationCenter()
        let manager = NotificationManager(center: center)
        #expect(center.delegate === manager)
        #expect(center.requests.isEmpty)
        manager.requestPermission()
        #expect(center.authorization == [.alert, .sound, .badge])
    }

    @Test func deliveryUsesRealNotificationPayloadAndOneShotTrigger() throws {
        let center = FixtureNotificationCenter()
        let manager = NotificationManager(center: center, now: { Date(timeIntervalSince1970: 123) })
        manager.sendScanComplete(bytesFound: 2_000_000_000)
        let request = try #require(center.requests.first)
        #expect(request.identifier == "weekly-scan-123.0")
        #expect(request.content.title == ScanNotificationContent.title)
        #expect(request.content.body == ScanNotificationContent.formattedBody(for: 2_000_000_000))
        #expect(request.content.categoryIdentifier == ScanNotificationContent.categoryIdentifier)
        #expect(request.content.sound != nil)
        let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 1)
        #expect(!trigger.repeats)
        #expect(NotificationManager.foregroundPresentation == [.banner, .sound])
    }

    @Test func responseCompletesPromptlyAndOpensApplicationOnMainActor() async {
        var opened = false
        var completed = false
        let manager = NotificationManager(center: FixtureNotificationCenter(), openApplication: { opened = true })
        manager.handleOpen { completed = true }
        #expect(completed)
        for _ in 0..<1_000 where !opened { await Task.yield() }
        #expect(opened)
    }
}

private final class FixtureNotificationCenter: ScanNotificationCenter {
    weak var delegate: UNUserNotificationCenterDelegate?
    var authorization: UNAuthorizationOptions = []
    var requests: [UNNotificationRequest] = []
    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping (Bool, Error?) -> Void) {
        authorization = options
        completion(true, nil)
    }
    func add(_ request: UNNotificationRequest) { requests.append(request) }
}
