import Foundation

@testable import MacSweepCore

struct XcodeFixture: ~Copyable {
    let root: URL
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".xcode-cleanup-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func directory(_ path: String, age: TimeInterval = 100 * 86_400) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: url.appendingPathComponent("symbols.bin"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
    func archive(_ name: String, app: String?, date: Date) throws -> URL {
        let url = try directory("Library/Developer/Xcode/Archives/2020-01-01/\(name).xcarchive")
        var info: [String: Any] = ["CreationDate": date]
        if let app { info["ApplicationProperties"] = ["CFBundleIdentifier": app] }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        return url
    }
    func service(
        command: @escaping XcodeCommand = { _, _, _ in ProcessResult(status: 1, output: "", error: "missing") },
        activity: @escaping @Sendable () async throws -> DevProcessSnapshot = { DevProcessSnapshot() },
        rules: @escaping @Sendable () -> UserProtectionRules = { .empty },
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        guardLimit: Int64 = 10_737_418_240
    ) -> XcodeCleanupService {
        var guardPolicy = DeletionGuard()
        guardPolicy.maxTotalSize = guardLimit
        return XcodeCleanupService(
            home: root, applications: [root.appendingPathComponent("Applications")],
            systemCaches: nil, command: command, activity: activity, rules: rules, trash: trash,
            deletionGuard: guardPolicy)
    }
}

actor XcodeNativeFixture {
    let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    var removed = false
    var failDeletion = false
    var runtimeAvailable = false
    var state = "Ready"
    var calls: [[String]] = []
    var unrelatedBooted = false
    var bootAfterSummaries: Int?
    var summaryCount = 0
    func configureUnrelatedBoot(booted: Bool = false, afterSummaries: Int? = nil) {
        unrelatedBooted = booted
        bootAfterSummaries = afterSummaries
    }
    var deviceState: String?
    var deviceAvailable = false
    var deviceRemoved = false
    var selectedDeveloper = "/Applications/Xcode.app/Contents/Developer"
    func configureDevice(state: String, available: Bool = false) {
        deviceState = state
        deviceAvailable = available
    }
    func select(_ path: String) { selectedDeveloper = path }

    func configure(fail: Bool = false, available: Bool = false, state: String = "Ready") {
        failDeletion = fail
        runtimeAvailable = available
        self.state = state
    }
    private func json(_ object: [String: Any]) throws -> String {
        guard let value = String(bytes: try JSONSerialization.data(withJSONObject: object), encoding: .utf8) else {
            throw XcodeCleanupError("Invalid fixture JSON")
        }
        return value
    }
    private func deviceRecords() -> [[String: Any]] {
        guard let deviceState, !deviceRemoved else { return [] }
        return [
            [
                "udid": id.uuidString, "name": "Fixture simulator", "state": deviceState,
                "isAvailable": deviceAvailable
            ]
        ]
    }
    private func deviceMap() -> [String: [[String: Any]]] {
        summaryCount += 1
        var values = ["com.apple.CoreSimulator.SimRuntime.iOS-1-0": deviceRecords()]
        if unrelatedBooted || bootAfterSummaries.map({ summaryCount >= $0 }) == true {
            values["com.apple.CoreSimulator.SimRuntime.iOS-other"] = [
                [
                    "udid": "11111111-2222-3333-4444-555555555555", "name": "Unrelated device",
                    "state": "Booted", "isAvailable": true
                ]
            ]
        }
        return values
    }
    private func runtimeRecords() -> [String: Any] {
        guard !removed else { return [:] }
        return [
            id.uuidString: [
                "identifier": id.uuidString,
                "path": "/Library/Developer/CoreSimulator/Images/fixture.dmg",
                "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-1-0",
                "deletable": true, "state": state, "sizeBytes": 4096, "version": "1.0", "build": "test"
            ]
        ]
    }
    private func deletion(isRuntime: Bool) -> ProcessResult {
        if failDeletion { return ProcessResult(status: 1, output: "", error: "denied") }
        if isRuntime { removed = true } else { deviceRemoved = true }
        return ProcessResult(status: 0, output: "", error: "")
    }
    func invoke(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> ProcessResult {
        calls.append(arguments)
        let output: String
        switch arguments {
        case ["-p"]: output = selectedDeveloper
        case ["--find", "simctl"]: output = selectedDeveloper + "/usr/bin/simctl"
        case ["simctl", "help", "runtime"]: output = "delete (<identifier>|--unusable) list [-j]"
        case ["simctl", "help", "delete"]: output = "Usage: simctl delete <device>"
        case ["simctl", "list", "-j"]:
            output = try json([
                "devices": deviceMap(),
                "runtimes": [
                    ["identifier": "com.apple.CoreSimulator.SimRuntime.iOS-1-0", "isAvailable": runtimeAvailable]
                ]
            ])
        case ["simctl", "runtime", "list", "-j"]:
            output = try json(runtimeRecords())
        case ["simctl", "runtime", "delete", id.uuidString]:
            return deletion(isRuntime: true)
        case ["simctl", "delete", id.uuidString]:
            return deletion(isRuntime: false)
        default: throw XcodeCleanupError("Unexpected command \(executable) \(arguments), \(timeout)")
        }
        if arguments.contains("help") { return ProcessResult(status: 0, output: "", error: output) }
        return ProcessResult(status: 0, output: output, error: "")
    }
}
