import Foundation

@testable import MacSweepCore

final class LocalSnapshotFixture: @unchecked Sendable {
    let lock = NSLock()
    var names = ["com.apple.TimeMachine.2026-01-02-030405.local", "com.apple.TimeMachine.2026-01-01-030405.local"]
    var running = false
    var failNative = false
    var nativeWarning = false
    var failAdmin = false
    var failAfterAdmin = false
    var malformed = false
    var volumeID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    var permissions = LocalSnapshotPermissions(hasFullDiskAccess: true, authorizationAvailable: true)
    var rules = UserProtectionRules.empty
    var adminCalls: [LocalSnapshotThinningTarget] = []
    var commandCalls: [[String]] = []
    var available: Int64 = 10_000
    var important: Int64? = 20_000

    func update(_ mutation: (LocalSnapshotFixture) -> Void) { lock.withLock { mutation(self) } }
    func permissionSnapshot() -> LocalSnapshotPermissions { lock.withLock { permissions } }
    func ruleSnapshot() -> UserProtectionRules { lock.withLock { rules } }
    func capacitySnapshot() -> LocalSnapshotCapacity {
        lock.withLock {
            LocalSnapshotCapacity(
                available: VolumeSpaceSnapshot(
                    timestamp: Date(), volumeID: volumeID, volumePath: "/",
                    availableBytes: available, errorMessage: nil),
                importantUsageBytes: important)
        }
    }
    func invoke(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> ProcessResult {
        try lock.withLock {
            commandCalls.append(arguments)
            if failNative || failAfterAdmin && !adminCalls.isEmpty {
                return ProcessResult(status: 1, output: "", error: "fixture native failure")
            }
            let output: String
            switch arguments {
            case ["help", "thinlocalsnapshots"]:
                return ProcessResult(
                    status: 0, output: "",
                    error: "Usage: tmutil thinlocalsnapshots <mount_point> [purgeamount] [urgency]")
            case ["info", "-plist", "/"]:
                let data = try PropertyListSerialization.data(
                    fromPropertyList: ["FilesystemType": "apfs", "MountPoint": "/", "VolumeUUID": volumeID],
                    format: .xml, options: 0)
                output = try text(data)
            case ["listlocalsnapshots", "/"]:
                output = "Snapshots for disk /:\n" + (malformed ? "unknown\n" : names.joined(separator: "\n"))
            case ["status"]:
                output = "Backup session status:\n{ Running = \(running ? 1 : 0); }"
            default: throw LocalSnapshotError("Unexpected fixture command \(executable), \(arguments), \(timeout)")
            }
            return ProcessResult(status: 0, output: output, error: nativeWarning ? "partial inventory warning" : "")
        }
    }
    func authorize(_ target: LocalSnapshotThinningTarget) throws {
        try lock.withLock {
            adminCalls.append(target)
            if failAdmin { throw LocalSnapshotError("Authorization declined") }
            names = []
            available += 1000
            important = important.map { $0 - 2000 }
        }
    }
    private func text(_ data: Data) throws -> String {
        guard let value = String(bytes: data, encoding: .utf8) else { throw LocalSnapshotError("Invalid fixture text") }
        return value
    }
    func service(limit: Int64 = 10_737_418_240) -> LocalSnapshotService {
        var guardPolicy = DeletionGuard()
        guardPolicy.maxTotalSize = limit
        let policy = guardPolicy
        return LocalSnapshotService(
            command: { try self.invoke($0, $1, $2) }, privileged: { try self.authorize($0) },
            permissions: { self.permissionSnapshot() }, capacity: { self.capacitySnapshot() },
            rules: { self.ruleSnapshot() }, guardPolicy: { policy })
    }
}
