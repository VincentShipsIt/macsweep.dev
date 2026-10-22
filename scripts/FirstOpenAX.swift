import AppKit
import ApplicationServices
import Foundation

final class FirstOpenAXDriver {
    private var button: AXUIElement?

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func snapshot() throws -> FirstOpenDialog {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: FirstOpenPolicy.owner)
        guard apps.count == 1, let app = apps.first,
            app.bundleURL?.resolvingSymlinksInPath().path == FirstOpenPolicy.ownerPath
        else { throw FirstOpenFailure(message: "Expected Apple first-open agent is not uniquely present.") }
        try FirstOpenPolicy.verifySignature(
            path: FirstOpenPolicy.ownerPath, requirement: "anchor apple and identifier \"\(FirstOpenPolicy.owner)\"")
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement], windows.count == 1,
            let window = windows.first
        else { throw FirstOpenFailure(message: "Expected exactly one Apple first-open dialog.") }
        var pending = [window]
        var texts: [String] = []
        var buttons: [String] = []
        var openButtons: [AXUIElement] = []
        var count = 0
        let deadline = Date().addingTimeInterval(5)
        while let element = pending.popLast() {
            count += 1
            guard count <= 128, Date() < deadline else {
                throw FirstOpenFailure(message: "Dialog inspection incomplete; refused.")
            }
            let role = attribute(element, kAXRoleAttribute) as? String
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            if role == kAXStaticTextRole {
                texts.append(attribute(element, kAXValueAttribute) as? String ?? title)
            } else if role == kAXButtonRole {
                let label = title.isEmpty ? attribute(element, kAXDescriptionAttribute) as? String ?? "" : title
                buttons.append(label)
                if label == "Open", attribute(element, kAXEnabledAttribute) as? Bool == true {
                    openButtons.append(element)
                }
            }
            pending += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard openButtons.count == 1 else { throw FirstOpenFailure(message: "Unique enabled Open button missing.") }
        button = openButtons.first
        return FirstOpenDialog(
            owner: FirstOpenPolicy.owner, ownerPath: FirstOpenPolicy.ownerPath,
            processID: app.processIdentifier, texts: texts.sorted(), buttons: buttons.sorted())
    }

    func press() throws {
        guard let button, AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw FirstOpenFailure(message: "The exact normal Open button could not be pressed.")
        }
    }
}

@main
struct FirstOpenAX {
    @MainActor static func main() throws {
        try FirstOpenPolicy.requireRunner()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if CommandLine.arguments.dropFirst() == ["--capabilities"] {
            print("{\"accessibilityTrusted\":\(trusted),\"promptRequested\":false}")
            return
        }
        guard trusted else { exit(77) }
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let evidence = URL(fileURLWithPath: CommandLine.arguments[1])
        let driver = FirstOpenAXDriver()
        var events: [FirstOpenEvent] = []
        let actions = FirstOpenActions(
            snapshot: { try driver.snapshot() },
            screenshot: { name in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", evidence.appendingPathComponent(name).path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw FirstOpenFailure(message: "Screenshot capture failed; no approval.")
                }
            },
            authorize: { try FirstOpenPolicy.authorize(evidence: evidence) },
            pressOpen: { try driver.press() },
            record: { event in
                events.append(event)
                try JSONEncoder().encode(events).write(to: evidence.appendingPathComponent("first-open-events.json"))
            })
        let deadline = Date().addingTimeInterval(20)
        while NSRunningApplication.runningApplications(withBundleIdentifier: FirstOpenPolicy.owner).isEmpty,
            Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        try FirstOpenPolicy.confirm(actions)
    }
}
