import Foundation

@testable import MacSweepCore

struct VirtualMachineFixture: ~Copyable {
    let root: URL
    let tool: URL
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".virtual-machine-fixture-\(UUID().uuidString)")
        tool = root.appendingPathComponent("bin/limactl")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("owned fixture executable".utf8).write(to: tool)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func directory(_ relative: String, marker: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 4096).write(to: url.appendingPathComponent("disk.img"))
        if let marker { try Data("{}".utf8).write(to: url.appendingPathComponent(marker)) }
        return url
    }
    func bundle(_ name: String, id: String) throws {
        let contents = try directory("Applications/\(name).app/Contents")
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
    }
    func service(
        native: VirtualMachineNativeFixture? = nil,
        activity: @escaping @Sendable () async throws -> DevProcessSnapshot = { DevProcessSnapshot() },
        rules: @escaping @Sendable () -> UserProtectionRules = { .empty },
        limit: Int64 = 10_737_418_240
    ) -> VirtualMachineService {
        var guardPolicy = DeletionGuard()
        guardPolicy.maxTotalSize = limit
        let policy = guardPolicy
        let toolPath = tool.path
        return VirtualMachineService(
            home: root, applications: [root.appendingPathComponent("Applications")],
            command: { executable, arguments, timeout in
                guard let native else { throw VirtualMachineError("No native manager") }
                return try native.invoke(executable, arguments, timeout)
            }, executable: { $0 == .lima && native != nil ? toolPath : nil },
            activity: activity, rules: rules, guardPolicy: { policy })
    }
}

final class VirtualMachineNativeFixture: @unchecked Sendable {
    let lock = NSLock()
    let home: URL
    var rows: [[String: Any]]
    var deletedNames: [String] = []
    var failNames: Set<String> = []
    var version = "limactl version 2.2.1"
    var listCount = 0
    var bootAfterLists: Int?
    var protectAfterLists: Int?
    var nativeFailure = false
    var calls: [[String]] = []
    init(home: URL, names: [String] = ["example"]) {
        self.home = home
        rows = names.map { name in
            [
                "name": name, "status": "Stopped", "dir": home.appendingPathComponent(".lima/\(name)").path,
                "protected": false, "vmType": "vz", "hostAgentPID": 0, "driverPID": 0, "disk": 10_737_418_240
            ]
        }
    }
    func update(_ block: (VirtualMachineNativeFixture) -> Void) { lock.withLock { block(self) } }
    func invoke(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) throws -> ProcessResult {
        try lock.withLock {
            calls.append(arguments)
            if nativeFailure { return ProcessResult(status: 1, output: "", error: "native failure") }
            switch arguments {
            case ["--version"]: return ProcessResult(status: 0, output: version, error: "")
            case ["delete", "--help"]:
                return ProcessResult(
                    status: 0, output: "",
                    error: "Usage: limactl delete INSTANCE --force Forcibly kill the processes")
            case ["list", "--json", "--all-fields"]:
                listCount += 1
                if let bootAfterLists, listCount >= bootAfterLists, !rows.isEmpty { rows[0]["status"] = "Running" }
                if let protectAfterLists, listCount >= protectAfterLists, !rows.isEmpty { rows[0]["protected"] = true }
                let data = try JSONSerialization.data(withJSONObject: rows)
                guard let output = String(bytes: data, encoding: .utf8) else {
                    throw VirtualMachineError("Invalid JSON")
                }
                return ProcessResult(status: 0, output: output, error: "")
            default:
                guard arguments.count == 3, arguments[0] == "--tty=false", arguments[1] == "delete" else {
                    throw VirtualMachineError("Unexpected native command \(executable), \(arguments), \(timeout)")
                }
                let name = arguments[2]
                if failNames.contains(name) { return ProcessResult(status: 1, output: "", error: "fixture refusal") }
                rows.removeAll { $0["name"] as? String == name }
                deletedNames.append(name)
                try FileManager.default.removeItem(at: home.appendingPathComponent(".lima/\(name)"))
                return ProcessResult(status: 0, output: "", error: "")
            }
        }
    }
}
