import AppKit
import CoreGraphics
import Foundation

struct FreshInstallWindow: Codable {
    let id: UInt32
    let width: Double
    let height: Double
    let title: String?
}

struct FreshInstallObservation: Codable {
    let processID: Int32?
    let bundlePathMatches: Bool
    let finishedLaunching: Bool
    let windows: [FreshInstallWindow]
    let observedForSeconds: Double
    let visibleWindowStable: Bool
    let interactiveGatekeeperApproval: String
    let onboardingVisualReview: String
}

func qualifies(width: Double, height: Double, layer: Int, onScreen: Bool) -> Bool {
    onScreen && layer == 0 && width >= 200 && height >= 150
}

func visibleWindows(processID: Int32) -> [FreshInstallWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return rows.compactMap { row in
        guard let owner = row[kCGWindowOwnerPID as String] as? Int32, owner == processID,
            let layer = row[kCGWindowLayer as String] as? Int,
            let bounds = row[kCGWindowBounds as String] as? [String: Double],
            let width = bounds["Width"], let height = bounds["Height"],
            let onScreen = row[kCGWindowIsOnscreen as String] as? Bool,
            let identifier = row[kCGWindowNumber as String] as? UInt32,
            qualifies(width: width, height: height, layer: layer, onScreen: onScreen)
        else { return nil }
        return FreshInstallWindow(
            id: identifier, width: width, height: height,
            title: row[kCGWindowName as String] as? String)
    }
}

@main
struct FreshInstallProbe {
    private static func verifyFixtures() {
        precondition(qualifies(width: 1040, height: 800, layer: 0, onScreen: true))
        precondition(!qualifies(width: 10, height: 10, layer: 0, onScreen: true))
        precondition(!qualifies(width: 1040, height: 800, layer: 2, onScreen: true))
        precondition(!qualifies(width: 1040, height: 800, layer: 0, onScreen: false))
        print("Window predicate fixtures passed; no application was launched or inspected.")
    }

    @MainActor static func main() throws {
        if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
            verifyFixtures()
            return
        }
        guard CommandLine.arguments.count == 3,
            ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
            ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"] == "github-hosted"
        else {
            fputs("Usage: FreshInstallProbe APP OUTPUT (GitHub-hosted runner only)\n", stderr)
            exit(2)
        }
        let app = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let start = Date()
        var firstVisible: Date?
        var result = FreshInstallObservation(
            processID: nil, bundlePathMatches: false, finishedLaunching: false, windows: [],
            observedForSeconds: 0, visibleWindowStable: false,
            interactiveGatekeeperApproval: "Not automatically approved; inspect actual runner outcome.",
            onboardingVisualReview: "Required using the actual first-launch screenshot.")
        repeat {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.macsweep.app")
            if applications.count == 1, let running = applications.first,
                running.bundleURL?.resolvingSymlinksInPath() == app, !running.isTerminated {
                let windows = visibleWindows(processID: running.processIdentifier)
                if running.isFinishedLaunching && !windows.isEmpty {
                    if firstVisible == nil { firstVisible = Date() }
                } else { firstVisible = nil }
                result = FreshInstallObservation(
                    processID: running.processIdentifier, bundlePathMatches: true,
                    finishedLaunching: running.isFinishedLaunching, windows: windows,
                    observedForSeconds: Date().timeIntervalSince(start),
                    visibleWindowStable: firstVisible.map { Date().timeIntervalSince($0) >= 5 } ?? false,
                    interactiveGatekeeperApproval: "No automated approval or security override was performed.",
                    onboardingVisualReview: "Required using the actual first-launch screenshot.")
            } else { firstVisible = nil }
            if result.visibleWindowStable { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date().timeIntervalSince(start) < 45
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: output)
        if let text = String(data: data, encoding: .utf8) { print(text) }
        guard result.visibleWindowStable else {
            fputs(
                "No stable installed-app window observed. "
                    + "Preserve artifacts; inspect Gatekeeper/session/crash evidence.\n", stderr)
            exit(1)
        }
    }
}
