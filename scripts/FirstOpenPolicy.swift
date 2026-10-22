import CryptoKit
import Darwin
import Foundation
import Security

struct FirstOpenDialog: Codable, Equatable {
    let owner: String
    let ownerPath: String
    let processID: Int32
    let texts: [String]
    let buttons: [String]
}

struct FirstOpenEvent: Codable {
    let phase: String
    let dialog: FirstOpenDialog?
    let detail: String
}

enum FirstOpenPending: Error { case notYetPresent }

struct FirstOpenFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct FirstOpenActions {
    let snapshot: () throws -> FirstOpenDialog
    let screenshot: (String) throws -> Void
    let authorize: () throws -> Void
    let pressOpen: () throws -> Void
    let record: (FirstOpenEvent) throws -> Void
}

enum FirstOpenPolicy {
    static let owner = "com.apple.coreservices.uiagent"
    static let ownerPath = "/System/Library/CoreServices/CoreServicesUIAgent.app"
    static let appPath = "/Applications/MacSweep.app"
    static let question =
        "“MacSweep” is an app downloaded from the Internet. Are you sure you want to open it?"
    static let assurance = "Apple checked it for malicious software and none was detected."

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func validate(_ dialog: FirstOpenDialog) throws {
        let texts = dialog.texts.map(normalized).filter { !$0.isEmpty }
        let help = dialog.buttons.filter { ["?", "Help", "help"].contains($0) }
        let buttons = dialog.buttons.filter { !["?", "Help", "help"].contains($0) }.sorted()
        let timestamp = "(?:today|yesterday) at [0-9]{1,2}:[0-9]{2} (?:AM|PM)"
        let download = "^Homebrew Cask downloaded this file " + timestamp + "\\. "
            + NSRegularExpression.escapedPattern(for: assurance) + "$"
        guard dialog.owner == owner, dialog.ownerPath == ownerPath, dialog.processID > 0,
            help.count <= 1, buttons == ["Cancel", "Open"], texts.count == 2, texts.contains(question),
            texts.contains(where: { $0.range(of: download, options: .regularExpression) != nil })
        else { throw FirstOpenFailure(message: "Unexpected dialog; normal MacSweep first-open approval refused.") }
    }

    static func waitForDialog(
        snapshot: () throws -> FirstOpenDialog, until deadline: Date,
        now: () -> Date = { Date() }, pause: () -> Void
    ) throws {
        while now() < deadline {
            do {
                _ = try snapshot()
                return
            } catch FirstOpenPending.notYetPresent { pause() }
        }
        throw FirstOpenFailure(message: "Normal first-open dialog did not appear before the deadline.")
    }

    static func confirm(_ actions: FirstOpenActions) throws {
        let before = try actions.snapshot()
        try actions.record(FirstOpenEvent(phase: "observed", dialog: before, detail: "No action yet."))
        try validate(before)
        try actions.screenshot("first-open-before.png")
        try actions.authorize()
        let fresh = try actions.snapshot()
        try validate(fresh)
        guard fresh == before else { throw FirstOpenFailure(message: "Dialog changed before approval; refused.") }
        try actions.record(FirstOpenEvent(phase: "authorized", dialog: fresh, detail: "Exact normal Open only."))
        try actions.pressOpen()
        try actions.record(FirstOpenEvent(phase: "pressed", dialog: fresh, detail: "Pressed the normal Open button."))
        try actions.screenshot("first-open-after.png")
    }

    static func requireRunner() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted" else {
            throw FirstOpenFailure(message: "UI interaction is restricted to the disposable GitHub-hosted runner.")
        }
    }

    static func authorize(evidence: URL) throws {
        try requireRunner()
        let authorization = try JSONSerialization.jsonObject(
            with: Data(contentsOf: evidence.appendingPathComponent("first-open-authorization.json"))) as? [String: Any]
        let executable = URL(fileURLWithPath: appPath + "/Contents/MacOS/MacSweep")
        let size = try executable.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 100_000_000 else {
            throw FirstOpenFailure(message: "Installed executable size is unavailable or exceeds the verified bound.")
        }
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        let infoData = try Data(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard authorization?["appPath"] as? String == appPath,
            authorization?["executableSHA256"] as? String == hash,
            authorization?["verified"] as? Bool == true,
            let team = authorization?["teamIdentifier"] as? String,
            team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
            let version = authorization?["version"] as? String,
            info?["CFBundleIdentifier"] as? String == "dev.macsweep.app",
            info?["CFBundleShortVersionString"] as? String == version,
            info?["CFBundleVersion"] as? String == version,
            getxattr(appPath, "com.apple.quarantine", nil, 0, 0, 0) > 0
        else { throw FirstOpenFailure(message: "Verified installed-app identity/quarantine authorization missing.") }
        try verifySignature(path: appPath, requirement:
            "anchor apple generic and identifier \"dev.macsweep.app\" "
                + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
                + "and certificate leaf[subject.OU] = \"\(team)\"")
    }

    static func verifySignature(path: String, requirement: String) throws {
        var code: SecStaticCode?
        var expected: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
            SecRequirementCreateWithString(requirement as CFString, [], &expected) == errSecSuccess,
            let code, let expected,
            SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), expected) == errSecSuccess
        else { throw FirstOpenFailure(message: "Signed app/Apple dialog-owner validation failed.") }
    }
}
