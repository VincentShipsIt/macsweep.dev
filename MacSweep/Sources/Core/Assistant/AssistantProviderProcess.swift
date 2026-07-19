import Foundation

typealias AssistantCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> ProcessResult

/// Runs assistant provider CLIs through the shared argv-only subprocess boundary.
///
/// Assistant requests may legitimately run for several minutes, so they use a
/// longer explicit timeout than short system probes. `ProcessRunner` owns
/// concurrent pipe draining and process-group termination.
struct AssistantProviderProcess: Sendable {
    static let timeout: TimeInterval = 600

    private let commandRunner: AssistantCommandRunner

    init(
        commandRunner: @escaping AssistantCommandRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) {
        self.commandRunner = commandRunner
    }

    func run(
        provider: AssistantProviderKind,
        executable: String,
        arguments: [String]
    ) async throws -> String {
        do {
            let result = try await commandRunner(executable, arguments, Self.timeout)
            guard result.didSucceed else {
                throw AssistantConversationError.processFailed(
                    provider: provider,
                    message: Self.preferredMessage(from: result)
                )
            }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as AssistantConversationError {
            throw error
        } catch let error as ProcessRunnerError {
            throw AssistantConversationError.processFailed(
                provider: provider,
                message: Self.message(for: error)
            )
        } catch {
            throw AssistantConversationError.processFailed(
                provider: provider,
                message: error.localizedDescription
            )
        }
    }

    private static func preferredMessage(from result: ProcessResult) -> String {
        result.error.isEmpty ? result.output : result.error
    }

    private static func message(for error: ProcessRunnerError) -> String {
        switch error {
        case .timedOut(_, let partialResult):
            let partialMessage = preferredMessage(from: partialResult)
            return partialMessage.isEmpty ? error.description : partialMessage
        case .nonZeroExit(_, let stderr) where !stderr.isEmpty:
            return stderr
        case .launchFailed, .nonZeroExit:
            return error.description
        }
    }
}
