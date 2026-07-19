import Testing
import Foundation
@testable import MacSweepCore

private struct CacheAnalyzerCommandInvocation: Equatable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
}

private actor CacheAnalyzerCommandRecorder {
    private var invocations: [CacheAnalyzerCommandInvocation] = []

    func record(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) {
        invocations.append(CacheAnalyzerCommandInvocation(
            executable: executable,
            arguments: arguments,
            timeout: timeout
        ))
    }

    func recordedInvocations() -> [CacheAnalyzerCommandInvocation] {
        invocations
    }
}

/// Coverage for `CacheAnalyzer`'s deterministic parse + categorization. These are
/// the pieces that decide what the fast scan reports without any AI call, so they
/// must be exercised directly (the AI path is network-bound and out of scope).
struct CacheAnalyzerTests {
    private static let validAIResponse = """
    [{
      "path":"/Users/test/.cache/example",
      "size_estimate":"42 MB",
      "category":"Other",
      "regenerates_automatically":true,
      "reason":"Fixture"
    }]
    """

    // MARK: - parseFastScanOutput

    @Test func parseValidTabSeparatedLine() throws {
        // `du -sk` output: size in KiB, tab, path.
        let output = "1258291\t/Users/x/.npm/_cacache"
        let findings = CacheAnalyzer.parseFastScanOutput(output)
        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        let expectedBytes: Int64 = 1_258_291 * 1024
        #expect(finding.path == "/Users/x/.npm/_cacache")
        #expect(finding.sizeBytes == expectedBytes)
        #expect(finding.sizeText ==
            ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file))
        #expect(finding.source == "Fast Scan")
        #expect(finding.regeneratesAutomatically == true)
    }

    @Test func parseMultipleLines() {
        let output = "1258291\t/Users/x/.npm/_cacache\n4\t/Users/x/.cache/uv"
        let findings = CacheAnalyzer.parseFastScanOutput(output)
        #expect(findings.count == 2)
    }

    @Test func parseSkipsLinesMissingTab() {
        // du output without a tab (e.g. a stray warning line) yields no finding.
        let findings = CacheAnalyzer.parseFastScanOutput("totally not tab separated")
        #expect(findings.isEmpty)
    }

    @Test func parseSkipsEmptyInput() {
        #expect(CacheAnalyzer.parseFastScanOutput("").isEmpty)
    }

    @Test func parseSkipsLineWithEmptyPath() {
        // Size present, path blank → not a real entry.
        #expect(CacheAnalyzer.parseFastScanOutput("5120\t").isEmpty)
    }

    @Test func parseSkipsNonNumericSize() {
        // Human-readable sizes (pre-`du -sk` format, or stray garbage) don't parse.
        #expect(CacheAnalyzer.parseFastScanOutput("1.2G\t/Users/x/.npm/_cacache").isEmpty)
    }

    // MARK: - categorize (one representative path per Category)

    @Test func categorizeElectronChromium() {
        let path = "/Users/x/Library/Application Support/Slack/Code Cache"
        #expect(CacheAnalyzer.categorize(path: path) == .electronChromium)
    }

    @Test func categorizePackageManager() {
        #expect(CacheAnalyzer.categorize(path: "/Users/x/.npm/_cacache") == .packageManager)
    }

    @Test func categorizeAIToolCache() {
        // .claude wins over the devDebugLogs "log/debug" rule because AI-tool is
        // checked first — confirm a .claude path is not misfiled as Dev Debug.
        #expect(CacheAnalyzer.categorize(path: "/Users/x/.claude/telemetry") == .aiToolCache)
    }

    @Test func categorizeDevDebugLogs() {
        #expect(CacheAnalyzer.categorize(path: "/Users/x/Library/Logs/SomeApp/debug") == .devDebugLogs)
    }

    @Test func categorizeOther() {
        #expect(CacheAnalyzer.categorize(path: "/Users/x/Library/Application Support/RandomApp/Stuff") == .other)
    }

    // MARK: - Provider command boundary

    @Test func claudeUsesResolvedExecutableExactArgumentsAndTimeout() async throws {
        let recorder = CacheAnalyzerCommandRecorder()
        let analyzer = CacheAnalyzer(
            executableResolver: { command in
                command == "claude" ? "/test/bin/claude" : nil
            },
            commandRunner: { executable, arguments, timeout in
                await recorder.record(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
                return ProcessResult(
                    status: 0,
                    output: Self.validAIResponse,
                    error: ""
                )
            }
        )

        let result = await analyzer.runLocalAIScan(prompt: "fixture prompt")
        let invocations = await recorder.recordedInvocations()
        let invocation = try #require(invocations.first)

        #expect(invocation.executable == "/test/bin/claude")
        #expect(invocation.arguments.count == 4)
        #expect(invocation.arguments[0] == "-p")
        #expect(invocation.arguments[1] == "--json-schema")
        #expect(invocation.arguments[2].contains(#""type": "array""#))
        #expect(invocation.arguments[3] == "fixture prompt")
        #expect(invocation.timeout == 600)
        #expect(result.provider == "Claude CLI")
        #expect(result.findings.count == 1)
        #expect(result.error == nil)
    }

    @Test func codexUsesResolvedExecutableExactArgumentsAndTimeout() async throws {
        let recorder = CacheAnalyzerCommandRecorder()
        let analyzer = CacheAnalyzer(
            executableResolver: { command in
                command == "codex" ? "/test/bin/codex" : nil
            },
            commandRunner: { executable, arguments, timeout in
                await recorder.record(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout
                )
                return ProcessResult(
                    status: 0,
                    output: Self.validAIResponse,
                    error: ""
                )
            }
        )

        let result = await analyzer.runLocalAIScan(prompt: "fixture prompt")
        let invocations = await recorder.recordedInvocations()
        let invocation = try #require(invocations.first)

        #expect(invocation.executable == "/test/bin/codex")
        #expect(invocation.arguments.count == 10)
        #expect(Array(invocation.arguments.prefix(5)) == [
            "exec",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "--ephemeral"
        ])
        #expect(invocation.arguments[5] == "--output-schema")
        #expect(invocation.arguments[6].hasPrefix(
            FileManager.default.temporaryDirectory.path
        ))
        #expect(invocation.arguments[7] == "-o")
        #expect(invocation.arguments[8].hasPrefix(
            FileManager.default.temporaryDirectory.path
        ))
        #expect(invocation.arguments[9] == "fixture prompt")
        #expect(invocation.timeout == 600)
        #expect(result.provider == "Codex CLI")
        #expect(result.findings.count == 1)
        #expect(result.error == nil)
    }

    @Test func nonzeroExitPrefersProviderStderr() async {
        let analyzer = CacheAnalyzer(
            executableResolver: { command in
                command == "claude" ? "/test/bin/claude" : nil
            },
            commandRunner: { _, _, _ in
                ProcessResult(
                    status: 23,
                    output: "stdout fallback",
                    error: "provider stderr"
                )
            }
        )

        let result = await analyzer.runLocalAIScan(prompt: "fixture prompt")

        #expect(result.provider == nil)
        #expect(result.error == "Claude CLI scan failed: provider stderr")
    }

    @Test func launchFailureRemainsProviderAttributed() async {
        let analyzer = CacheAnalyzer(
            executableResolver: { command in
                command == "claude" ? "/test/bin/claude" : nil
            },
            commandRunner: { _, _, _ in
                throw ProcessRunnerError.launchFailed("permission denied")
            }
        )

        let result = await analyzer.runLocalAIScan(prompt: "fixture prompt")

        #expect(result.provider == nil)
        #expect(result.error ==
            "Claude CLI scan failed: Failed to launch process: permission denied")
    }

    @Test func timeoutPrefersPartialStderr() async {
        let analyzer = CacheAnalyzer(
            executableResolver: { command in
                command == "claude" ? "/test/bin/claude" : nil
            },
            commandRunner: { _, _, timeout in
                throw ProcessRunnerError.timedOut(
                    after: timeout,
                    partialResult: ProcessResult(
                        status: -1,
                        output: "partial stdout",
                        error: "partial stderr"
                    )
                )
            }
        )

        let result = await analyzer.runLocalAIScan(prompt: "fixture prompt")

        #expect(result.provider == nil)
        #expect(result.error ==
            "Claude CLI scan timed out after 600s: partial stderr")
    }

    @Test func timeoutFallsBackToPartialStdout() async {
        let analyzer = CacheAnalyzer(
            executableResolver: { command in
                command == "claude" ? "/test/bin/claude" : nil
            },
            commandRunner: { _, _, timeout in
                throw ProcessRunnerError.timedOut(
                    after: timeout,
                    partialResult: ProcessResult(
                        status: -1,
                        output: "partial stdout",
                        error: ""
                    )
                )
            }
        )

        let result = await analyzer.runLocalAIScan(prompt: "fixture prompt")

        #expect(result.provider == nil)
        #expect(result.error ==
            "Claude CLI scan timed out after 600s: partial stdout")
    }
}
