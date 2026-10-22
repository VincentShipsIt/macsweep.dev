import Foundation
import Testing

@testable import MacSweepCore

struct AuthorizedAdminStreamTests {
    actor Chunks {
        var text = ""
        func append(_ data: Data) { text += String(data: data, encoding: .utf8) ?? "" }
    }

    @Test func boundedAdministratorBridgeStreamsAndPreservesNativeFailure() async throws {
        let chunks = Chunks()
        let result = try await AuthorizedAdminStream.perform(
            trustedScript: "/usr/bin/printf 'first'; /bin/sleep 0.15; /usr/bin/printf 'second' >&2; exit 7",
            timeout: 10,
            onOutput: { _, data in Task { await chunks.append(data) } },
            executor: { try await PrivilegedRunner.runSupervisedShellScriptForTesting($0, timeout: $1) })
        #expect(result.status == 7)
        #expect(result.output == "first")
        #expect(result.error == "second")
        for _ in 0..<100 where await chunks.text.count < 11 { await Task.yield() }
        let text = await chunks.text
        #expect(text.contains("first") && text.contains("second"))
    }

    @Test func outputArrivesWhileTheNativeCommandIsStillRunning() async throws {
        let temp = try TempTestDirectory(prefix: "AdminStreamHandshake")
        let acknowledgement = temp.url.appendingPathComponent("first-chunk-seen")
        let quoted = PrivilegedRunner.shellQuote(acknowledgement.path)
        let script = """
            /usr/bin/printf 'before'
            count=0
            while [ ! -e \(quoted) ]; do
              count=$((count + 1)); [ "$count" -lt 100 ] || exit 23
              /bin/sleep 0.02
            done
            /usr/bin/printf 'after'
            """
        let result = try await AuthorizedAdminStream.perform(
            trustedScript: script, timeout: 10,
            onOutput: { stream, data in
                if stream == .standardOutput, !data.isEmpty { try? Data([1]).write(to: acknowledgement) }
            }, executor: { try await PrivilegedRunner.runSupervisedShellScriptForTesting($0, timeout: $1) })
        #expect(result.status == 0)
        #expect(result.output == "beforeafter")
    }

    @Test func noPrivilegeOrHelperExecutionOccursForUnsupportedMasRequest() async throws {
        let file = URL(fileURLWithPath: "/bin/sh")
        let identity = try DevArtifactIdentity.read(file)
        var metadata = stat()
        #expect(lstat(file.path, &metadata) == 0)
        #expect(throws: (any Error).self) {
            _ = try PrivilegedRunner.macStoreUpdateScript(
                executable: file, appID: 123,
                expectedIdentity: identity, expectedStamp: DevArtifactNode(path: file.path, status: metadata))
        }
    }
}
