import CryptoKit
import Darwin
import Foundation

extension PrivilegedRunner {
    /// Finite authorized action: the only data is a validated installed mas
    /// executable and numeric App Store ID. The ordinary script API remains
    /// constant-only. Service callers disclose authorization/sign-in beforehand.
    static func updateMacStoreApp(
        executable: URL, appID: UInt64,
        expectedIdentity: DevArtifactIdentity, expectedStamp: DevArtifactNode,
        onOutput: @escaping ProcessOutputHandler
    ) async throws -> ProcessResult {
        let script = try macStoreUpdateScript(
            executable: executable, appID: appID,
            expectedIdentity: expectedIdentity, expectedStamp: expectedStamp)
        return try await AuthorizedAdminStream.perform(trustedScript: script, timeout: 1_800, onOutput: onOutput)
    }

    static func macStoreUpdateScript(
        executable: URL, appID: UInt64,
        expectedIdentity: DevArtifactIdentity, expectedStamp: DevArtifactNode
    ) throws -> String {
        let supported = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas", "/opt/local/bin/mas"]
        guard appID > 0, supported.contains(executable.path),
            try DevArtifactIdentity.read(executable.resolvingSymlinksInPath()) == expectedIdentity
        else {
            throw DevArtifactSafetyError("The reviewed App Store helper changed or is unsupported.")
        }
        let resolved = executable.resolvingSymlinksInPath()
        var metadata = stat()
        guard lstat(resolved.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_mode & 0o111 != 0,
            DevArtifactNode(path: resolved.path, status: metadata) == expectedStamp
        else {
            throw DevArtifactSafetyError("The App Store helper content changed. Refresh updates.")
        }
        // Hash again after the authorization dialog, which can stay open for minutes.
        let digest = SHA256.hash(
            data: try AuthorizedFileEvidence.read(resolved, maximumBytes: 67_108_864, expected: expectedStamp)
        ).map { String(format: "%02x", $0) }.joined()
        let quoted = shellQuote(resolved.path)
        return """
            [ "$(/usr/bin/id -u)" = 0 ] || exit 125
            [ ! -L \(quoted) ] && [ -f \(quoted) ] || exit 125
            [ "$(/usr/bin/shasum -a 256 \(quoted) | /usr/bin/awk '{print $1}')" = '\(digest)' ] || exit 125
            exec \(quoted) update \(appID)
            """
    }
}
