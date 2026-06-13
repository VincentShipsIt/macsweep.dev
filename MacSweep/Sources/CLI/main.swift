import Foundation
import MacSweepCLIKit

@main
struct MacSweepCLIEntryPoint {
    static func main() async {
        do {
            let command = try CLICommandParser.parse(Array(CommandLine.arguments.dropFirst()))
            let status = try await CLIExecutor.run(command: command)
            exit(status)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            let code = CLIExecutor.exitCode(for: error)
            if code == CLIExitCode.usage.rawValue {
                fputs("\(CLIHelp.text)\n", stderr)
            }
            exit(code)
        }
    }
}
