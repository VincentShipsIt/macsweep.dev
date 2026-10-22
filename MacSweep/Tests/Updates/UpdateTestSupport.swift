import Foundation
import Testing

@testable import MacSweepCore

final class UpdateFixture {
    let temp: TempTestDirectory
    let root: URL
    let tools: [String: String]
    let runner: UpdateFixtureRunner

    init() throws {
        temp = try TempTestDirectory(prefix: "Updates")
        root = temp.url.resolvingSymlinksInPath()
        var paths: [String: String] = [:]
        for name in ["brew", "mas", "npm", "pnpm", "pipx", "gem"] {
            let executable = root.appendingPathComponent(name)
            try Data("fixture manager".utf8).write(to: executable)
            paths[name] = executable.path
        }
        for directory in [
            "install", "install/bin", "install/Cellar", "install/Caskroom", "install/node_modules",
            "install/pipx", "install/gems"
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        tools = paths
        runner = UpdateFixtureRunner(root: root)
    }

    func scanner(administrator: Bool = false) -> UpdateScanner {
        var scanner = UpdateScanner()
        let tools = tools
        scanner.managerPath = { tools[$0] }
        scanner.writableReason = { _ in nil }
        scanner.homebrewNoSudo = { _ in true }
        scanner.masExecutableAllowed = { _ in true }
        scanner.administratorAvailable = administrator
        let runner = runner
        scanner.commandRunner = { command, _ in await runner.query(command) }
        return scanner
    }

    func executor(administrator: MasAdministratorUpdate? = nil) -> UpdateExecutor {
        var executor = UpdateExecutor(
            scanner: scanner(administrator: administrator != nil), administratorUpdate: administrator)
        let runner = runner
        executor.streamingRunner = { command, output in await runner.update(command, output: output) }
        return executor
    }
}

actor UpdateFixtureRunner {
    let root: URL
    var latest = "2.0.0"
    var failureName: String?
    var failedPipQuery = false
    var pinnedPipx = false
    var updates: [UpdateCommand] = []
    var administratorRequests: [MasUpdateRequest] = []

    init(root: URL) { self.root = root }
    func setLatest(_ value: String) { latest = value }
    func fail(_ name: String) { failureName = name }
    func failPipQuery() { failedPipQuery = true }
    func pinPipx() { pinnedPipx = true }

    func query(_ command: UpdateCommand) -> ProcessResult {
        let args = nativeArguments(command)
        let source = args.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let action = args.dropFirst().first ?? ""
        let text: String
        if ["--prefix", "prefix", "root", "bin", "environment"].contains(action) {
            text = installPath(args: args, action: action)
        } else if source == "brew" {
            text = action == "info" ? #"{"casks":[{"artifacts":[{"app":["App.app"]}]}]}"# : brewJSON
        } else if source == "mas" {
            text = "12345 Example App (1.0.0 -> \(latest))"
        } else if source == "npm" || source == "pnpm" {
            text =
                "{\"foo\":{\"current\":\"1.0.0\",\"latest\":\"\(latest)\"},"
                + "\"bar\":{\"current\":\"1.0.0\",\"latest\":\"\(latest)\"}}"
        } else if source == "gem" {
            text = "rake (1.0.0 < \(latest))"
        } else if source == "pipx", action == "runpip" {
            if failedPipQuery { return .init(status: 2, output: "", error: "unsupported") }
            text = "[{\"name\":\"foo\",\"version\":\"1.0.0\",\"latest_version\":\"\(latest)\"}]"
        } else {
            text =
                #"{"venvs":{"foo":{"metadata":{"main_package":{"package":"foo","package_version":"1.0.0","#
                + #""pinned":false}}}}}"#
        }
        let output =
            source == "pipx" && action == "list" && pinnedPipx
            ? text.replacingOccurrences(of: "false", with: "true") : text
        return .init(status: source == "npm" && action == "outdated" ? 1 : 0, output: output, error: "")
    }

    private var brewJSON: String {
        "{\"formulae\":[{\"name\":\"wget\",\"installed_versions\":[\"1.0.0\"],"
            + "\"current_version\":\"\(latest)\",\"pinned\":false}],"
            + "\"casks\":[{\"name\":\"example\",\"installed_versions\":[\"1.0.0\"],\"current_version\":\"\(latest)\"}]}"
    }

    private func installPath(args: [String], action: String) -> String {
        if args.contains("PIPX_HOME") { return root.appendingPathComponent("install/pipx").path }
        if args.contains("PIPX_BIN_DIR") || action == "bin" { return root.appendingPathComponent("install/bin").path }
        if args.contains("gemdir") { return root.appendingPathComponent("install/gems").path }
        return root.appendingPathComponent(action == "root" ? "install/node_modules" : "install").path
    }

    func update(_ command: UpdateCommand, output: ProcessOutputHandler) -> ProcessResult {
        updates.append(command)
        output(.standardOutput, Data("fixture streamed output\n".utf8))
        let failed =
            failureName.map { name in command.arguments.contains { $0 == name || $0.hasPrefix(name + "@") } } ?? false
        return .init(status: failed ? 1 : 0, output: "", error: failed ? "fixture failure" : "")
    }

    func administrator(_ request: MasUpdateRequest, output: ProcessOutputHandler) -> ProcessResult {
        administratorRequests.append(request)
        output(.standardOutput, Data("administrator fixture output\n".utf8))
        return .init(status: 0, output: "", error: "")
    }

    private func nativeArguments(_ command: UpdateCommand) -> [String] {
        guard let index = command.arguments.firstIndex(where: { $0.hasPrefix(root.path + "/") }) else { return [] }
        return Array(command.arguments[index...])
    }
}
