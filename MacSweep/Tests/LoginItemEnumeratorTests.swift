import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for the root-only `sfltool dumpbtm` boundary and its pure text parser.
/// The real subprocess is host-dependent, so an injected runner verifies the exact
/// argv/timeout and fail-closed behavior while synthetic dump text exercises entry
/// extraction.
///
/// `LoginItemEnumerator` is an actor, so the parser is reached via `await`.
struct LoginItemEnumeratorTests {
    private let enumerator = LoginItemEnumerator()

    @Test func unprivilegedEnumerationSkipsSfltool() async {
        let recorder = LoginItemCommandRecorder(result: ProcessResult(
            status: 0,
            output: "",
            error: ""
        ))
        let enumerator = LoginItemEnumerator(
            isRoot: { false },
            commandRunner: { executable, arguments, timeout in
                try await recorder.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
            }
        )

        #expect(await enumerator.appServiceItems().isEmpty)
        #expect(await recorder.recordedInvocations().isEmpty)
    }

    @Test func rootEnumerationUsesBoundedExactArgvAndParsesStdout() async {
        let output = """
        {
            name = "Spotify"
            bundleIdentifier = "com.spotify.client"
            url = "file:///Applications/Spotify.app"
        }
        """
        let recorder = LoginItemCommandRecorder(result: ProcessResult(
            status: 0,
            output: output,
            error: "ignored diagnostic"
        ))
        let enumerator = LoginItemEnumerator(
            isRoot: { true },
            commandRunner: { executable, arguments, timeout in
                try await recorder.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
            }
        )

        let items = await enumerator.appServiceItems()

        #expect(items.count == 1)
        #expect(items.first?.name == "Spotify")
        #expect(await recorder.recordedInvocations() == [
            LoginItemCommandInvocation(
                executable: "/usr/bin/sfltool",
                arguments: ["dumpbtm"],
                timeout: 10
            )
        ])
    }

    @Test func nonzeroSfltoolExitFailsClosed() async {
        let recorder = LoginItemCommandRecorder(result: ProcessResult(
            status: 1,
            output: """
            {
                name = "Must Not Surface"
                url = "file:///Applications/Hidden.app"
            }
            """,
            error: "permission denied"
        ))
        let enumerator = LoginItemEnumerator(
            isRoot: { true },
            commandRunner: { executable, arguments, timeout in
                try await recorder.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
            }
        )

        #expect(await enumerator.appServiceItems().isEmpty)
    }

    @Test func timedOutSfltoolProbeFailsClosed() async {
        let recorder = LoginItemCommandRecorder(error: ProcessRunnerError.timedOut(
            after: 10,
            partialResult: ProcessResult(
                status: -1,
                output: """
                {
                    name = "Partial"
                    url = "file:///Applications/Partial.app"
                }
                """,
                error: ""
            )
        ))
        let enumerator = LoginItemEnumerator(
            isRoot: { true },
            commandRunner: { executable, arguments, timeout in
                try await recorder.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
            }
        )

        #expect(await enumerator.appServiceItems().isEmpty)
    }

    @Test func failedSfltoolLaunchFailsClosed() async {
        let recorder = LoginItemCommandRecorder(error: ProcessRunnerError.launchFailed(
            "sfltool unavailable"
        ))
        let enumerator = LoginItemEnumerator(
            isRoot: { true },
            commandRunner: { executable, arguments, timeout in
                try await recorder.run(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
            }
        )

        #expect(await enumerator.appServiceItems().isEmpty)
    }

    @Test func parsesWellFormedEntryWithFileURL() async {
        let output = """
        {
            name = "Spotify"
            bundleIdentifier = "com.spotify.client"
            url = "file:///Applications/Spotify.app"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.count == 1)
        #expect(items.first?.name == "Spotify")
        // file:// prefix stripped, leaving an absolute path.
        #expect(items.first?.path == "/Applications/Spotify.app")
        #expect(items.first?.bundleIdentifier == "com.spotify.client")
        #expect(items.first?.kind == .appService)
        #expect(items.first?.enabled == true)
    }

    @Test func parsesExecutableURLVariant() async {
        // Some entries spell the location `executableURL = …` instead of `url = …`;
        // both must resolve to the same path field.
        let output = """
        {
            name = "BackupHelper"
            executableURL = "file:///Applications/Backup.app/Contents/MacOS/helper"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.count == 1)
        #expect(items.first?.path == "/Applications/Backup.app/Contents/MacOS/helper")
    }

    @Test func parsesMultipleEntries() async {
        let output = """
        {
            name = "First"
            url = "file:///Applications/First.app"
        },
        {
            name = "Second"
            url = "file:///Applications/Second.app"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.count == 2)
        #expect(items.map(\.name) == ["First", "Second"])
    }

    @Test func skipsEntryMissingClosingBrace() async {
        // No `}` ever flushes the accumulated name/url, so a truncated final block
        // is dropped rather than emitted half-populated.
        let output = """
        {
            name = "Truncated"
            url = "file:///Applications/Truncated.app"
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.isEmpty)
    }

    @Test func skipsEntryWithoutPath() async {
        // A block with a name but no url/executableURL is not a usable login item.
        let output = """
        {
            name = "NameOnly"
            bundleIdentifier = "com.example.nopath"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.isEmpty)
    }

    @Test func parsesEmptyInputToNothing() async {
        #expect(await enumerator.parseSfltoolOutput("").isEmpty)
    }
}

private struct LoginItemCommandInvocation: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

private enum LoginItemCommandResponse: Sendable {
    case result(ProcessResult)
    case error(ProcessRunnerError)
}

private actor LoginItemCommandRecorder {
    private let response: LoginItemCommandResponse
    private var invocations: [LoginItemCommandInvocation] = []

    init(result: ProcessResult) {
        response = .result(result)
    }

    init(error: ProcessRunnerError) {
        response = .error(error)
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        invocations.append(LoginItemCommandInvocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))

        switch response {
        case .result(let result):
            return result
        case .error(let error):
            throw error
        }
    }

    func recordedInvocations() -> [LoginItemCommandInvocation] {
        invocations
    }
}
