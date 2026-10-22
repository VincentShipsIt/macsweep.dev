import Foundation
import Testing

@testable import MacSweepCore

final class ToolchainFixture {
    let root: URL
    let location: ToolchainLocation
    let projects: URL
    let date = Date(timeIntervalSince1970: 1_600_000_000)

    init(manager: ToolchainManager = .pyenv) throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".macsweep-toolchain-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        let managerRoot = root.appendingPathComponent(manager.rawValue)
        let executable = root.appendingPathComponent("manager")
        projects = root.appendingPathComponent("projects")
        location = ToolchainLocation(
            manager: manager, root: managerRoot, executable: manager == .java ? nil : executable)
        try FileManager.default.createDirectory(at: managerRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data("fixture manager".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func install(_ version: String = "3.8.0", tool: String? = nil) throws -> URL {
        let relative: String
        switch location.manager {
        case .nvm: relative = "versions/node/" + version
        case .pyenv, .rbenv: relative = "versions/" + version
        case .rustup: relative = "toolchains/" + version
        case .asdf, .mise: relative = "installs/" + (tool ?? "python") + "/" + version
        case .java: relative = version + ".jdk"
        }
        let path = location.root.appendingPathComponent(relative)
        let bin = path.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("runtime")
        try Data(repeating: 1, count: 4096).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755, .modificationDate: date], ofItemAtPath: executable.path)
        // Reading metadata does not update atime; explicitly old atime makes this a deterministic age fixture.
        try setAccessDate(executable)
        return path
    }

    private func setAccessDate(_ path: URL) throws {
        let command = ToolchainCommand(executable: "/usr/bin/touch", arguments: ["-a", "-t", "202009131226", path.path])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    func service(runner: ToolchainRecordingRunner = .init()) -> ToolchainService {
        var service = ToolchainService()
        service.home = root
        service.environment = [:]
        service.locationsOverride = [location]
        service.referenceRootsOverride = [projects]
        service.activity = { DevProcessSnapshot() }
        service.commandRunner = { command, timeout in try await runner.run(command, timeout: timeout) }
        return service
    }
}

actor ToolchainRecordingRunner {
    var commands: [ToolchainCommand] = []
    var help = "uninstall --no-config --no-env --no-hooks"
    var failure = false
    var removePaths: [String: URL] = [:]

    func configure(help: String? = nil, failure: Bool = false, removePaths: [String: URL] = [:]) {
        if let help { self.help = help }
        self.failure = failure
        self.removePaths = removePaths
    }

    func run(_ command: ToolchainCommand, timeout: TimeInterval) throws -> ProcessResult {
        commands.append(command)
        if command.arguments.contains("help") || command.arguments.contains("--help")
            || command.arguments.contains(where: { $0.contains("nvm --help") }) {
            return ProcessResult(status: 0, output: help, error: "")
        }
        if failure { return ProcessResult(status: 1, output: "", error: "fixture failure") }
        for (version, path) in removePaths where command.arguments.contains(version) {
            try FileManager.default.removeItem(at: path)
        }
        return ProcessResult(status: 0, output: "", error: "")
    }

    var mutations: [ToolchainCommand] {
        commands.filter {
            $0.arguments.contains("-f") || $0.arguments.contains("toolchain") && !$0.arguments.contains("--help")
        }
    }
}
