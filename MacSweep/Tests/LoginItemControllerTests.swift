import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for `LoginItemController`, the headless mutation path for launch
/// agents / daemons. Fixtures are synthetic plists in injected temp directories
/// so the tests never touch the real `~/Library/LaunchAgents`. The controller
/// resolves items by their parsed launchd `Label` (not by filename), so these
/// exercise: a label that matches nothing (notFound), a label present in two
/// searched directories (ambiguous), a successful `Disabled`-key toggle, and a
/// recoverable trash-based removal.
final class LoginItemControllerTests {
    private let userDir: URL
    private let systemDir: URL
    private let daemonDir: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepLoginItemTests-\(UUID().uuidString)")
        userDir = base.appendingPathComponent("user")
        systemDir = base.appendingPathComponent("system")
        daemonDir = base.appendingPathComponent("daemons")
        for dir in [userDir, systemDir, daemonDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit {
        let base = userDir.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: base)
    }

    private func controller() -> LoginItemController {
        LoginItemController(
            userLaunchAgents: userDir,
            systemLaunchAgents: systemDir,
            systemLaunchDaemons: daemonDir
        )
    }

    /// Write a synthetic launch-agent plist with the given Label into `dir`.
    @discardableResult
    private func writePlist(label: String, disabled: Bool? = nil, in dir: URL, fileName: String? = nil) throws -> URL {
        var plist: [String: Any] = ["Label": label, "ProgramArguments": ["/usr/bin/true"]]
        if let disabled { plist["Disabled"] = disabled }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = dir.appendingPathComponent((fileName ?? label) + ".plist")
        try data.write(to: url)
        return url
    }

    @Test func setEnabledThrowsNotFoundForUnknownLabel() async throws {
        try writePlist(label: "com.example.present", in: userDir)
        let controller = controller()
        await #expect(throws: LoginItemController.MutationError.self) {
            _ = try await controller.setEnabled(false, label: "com.example.absent")
        }
    }

    @Test func setEnabledThrowsAmbiguousWhenLabelInTwoDirs() async throws {
        // Same Label declared in both the user and system agent directories.
        try writePlist(label: "com.example.dup", in: userDir)
        try writePlist(label: "com.example.dup", in: systemDir)
        let controller = controller()

        do {
            _ = try await controller.setEnabled(false, label: "com.example.dup")
            Issue.record("Expected MutationError.ambiguous for a label present in two directories")
        } catch let error as LoginItemController.MutationError {
            guard case .ambiguous(let paths) = error else {
                Issue.record("Expected .ambiguous, got \(error)")
                return
            }
            #expect(paths.count == 2)
        }
    }

    @Test func setEnabledFalseWritesDisabledTrue() async throws {
        // Filename intentionally differs from the Label to prove resolution is
        // by parsed Label, not filename.
        let url = try writePlist(label: "com.example.toggle", in: userDir, fileName: "renamed-agent")
        let controller = controller()

        let outcome = try await controller.setEnabled(false, label: "com.example.toggle")
        #expect(outcome.enabled == false)
        #expect(outcome.removed == false)
        // Compare resolved paths — temp dirs surface as /var/folders here but
        // /private/var/folders after enumeration (the /private symlink).
        #expect(URL(fileURLWithPath: outcome.plistPath).resolvingSymlinksInPath()
            == url.resolvingSymlinksInPath())

        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["Disabled"] as? Bool == true)
    }

    @Test func setEnabledTrueWritesDisabledFalse() async throws {
        let url = try writePlist(label: "com.example.reenable", disabled: true, in: userDir)
        let controller = controller()

        let outcome = try await controller.setEnabled(true, label: "com.example.reenable")
        #expect(outcome.enabled == true)

        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(plist?["Disabled"] as? Bool == false)
    }

    @Test func removeMovesPlistOutOfSourceDirectory() async throws {
        let url = try writePlist(label: "com.example.remove", in: userDir)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let controller = controller()

        let outcome = try await controller.remove(label: "com.example.remove")
        #expect(outcome.removed == true)
        // trashItem relocates the file; it must no longer exist at the source.
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }
}
