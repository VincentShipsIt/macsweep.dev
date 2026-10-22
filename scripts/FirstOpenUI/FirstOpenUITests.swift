import AppKit
import XCTest

@MainActor
final class FirstOpenUITests: XCTestCase {
    private let agent = XCUIApplication(bundleIdentifier: FirstOpenPolicy.owner)

    private func snapshot() throws -> FirstOpenDialog {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: FirstOpenPolicy.owner)
        guard apps.count == 1, let app = apps.first,
            app.bundleURL?.resolvingSymlinksInPath().path == FirstOpenPolicy.ownerPath,
            agent.windows.count == 1
        else { throw FirstOpenFailure(message: "Expected one Apple-owned confirmation window.") }
        try FirstOpenPolicy.verifySignature(
            path: FirstOpenPolicy.ownerPath, requirement: "anchor apple and identifier \"\(FirstOpenPolicy.owner)\"")
        let window = agent.windows.element(boundBy: 0)
        return FirstOpenDialog(
            owner: FirstOpenPolicy.owner, ownerPath: FirstOpenPolicy.ownerPath,
            processID: app.processIdentifier,
            texts: window.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label).sorted(),
            buttons: window.descendants(matching: .button).allElementsBoundByIndex.map(\.label).sorted())
    }

    private func recordOnboarding(evidence: URL) throws {
        let installed = XCUIApplication(url: URL(fileURLWithPath: FirstOpenPolicy.appPath))
        guard installed.staticTexts["Welcome to MacSweep"].waitForExistence(timeout: 25) else {
            throw FirstOpenFailure(message: "Initial onboarding text was not observed; preserve actual UI evidence.")
        }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.macsweep.app")
        guard apps.count == 1, let app = apps.first,
            app.bundleURL?.resolvingSymlinksInPath().path == FirstOpenPolicy.appPath else {
            throw FirstOpenFailure(message: "Onboarding process does not match the installed app.")
        }
        let receipt: [String: Any] = ["text": "Welcome to MacSweep", "processID": app.processIdentifier,
                                     "bundlePathMatches": true, "windowCount": installed.windows.count]
        try JSONSerialization.data(withJSONObject: receipt, options: .prettyPrinted)
            .write(to: evidence.appendingPathComponent("native-onboarding.json"))
        try XCUIScreen.main.screenshot().pngRepresentation
            .write(to: evidence.appendingPathComponent("first-launch-onboarding.png"))
    }

    func testExactNormalFirstOpen() throws {
        continueAfterFailure = false
        try FirstOpenPolicy.requireRunner()
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MACSWEEP_ACCEPTANCE_EVIDENCE"], !path.isEmpty else {
            throw FirstOpenFailure(message: "Missing verified runner evidence directory.")
        }
        let evidence = URL(fileURLWithPath: path)
        var events: [FirstOpenEvent] = []
        let actions = FirstOpenActions(
            snapshot: { try self.snapshot() },
            screenshot: { name in
                let screenshot = XCUIScreen.main.screenshot()
                try screenshot.pngRepresentation.write(to: evidence.appendingPathComponent(name))
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = name
                attachment.lifetime = .keepAlways
                self.add(attachment)
            },
            authorize: { try FirstOpenPolicy.authorize(evidence: evidence) },
            pressOpen: {
                let open = self.agent.windows.element(boundBy: 0)
                    .descendants(matching: .button).matching(identifier: "Open")
                guard open.count == 1, open.element(boundBy: 0).isHittable else {
                    throw FirstOpenFailure(message: "Unique hittable normal Open missing; refused.")
                }
                open.element(boundBy: 0).click()
            },
            record: { event in
                events.append(event)
                try JSONEncoder().encode(events).write(to: evidence.appendingPathComponent("first-open-events.json"))
            })
        guard agent.windows.firstMatch.waitForExistence(timeout: 20) else {
            throw FirstOpenFailure(message: "Expected first-open window did not appear.")
        }
        try FirstOpenPolicy.confirm(actions)
        try recordOnboarding(evidence: evidence)
    }
}
