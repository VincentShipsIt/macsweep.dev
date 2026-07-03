import Foundation
import Testing
@testable import MacSweepCore

/// Regression tests for #84: `SSHKnownHostsManager.removeHost` now serializes its
/// read-modify-write behind an advisory `flock` and re-reads under the lock, so
/// concurrent removals can't lose each other's edits.
final class SSHKnownHostsManagerTests {
    let dir: URL
    var knownHosts: URL { dir.appendingPathComponent("known_hosts") }

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepKnownHosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func host(_ rawLine: String) -> SSHKnownHost {
        SSHKnownHost(host: rawLine, rawLine: rawLine, algorithm: "ssh-ed25519", isHashed: false)
    }

    private func lines(of file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    @Test func removesOnlyTheTargetedLine() throws {
        let contents = ["host-a key-a", "host-b key-b", "host-c key-c"].joined(separator: "\n") + "\n"
        try contents.write(to: knownHosts, atomically: true, encoding: .utf8)

        try SSHKnownHostsManager.removeHost(host("host-b key-b"), from: knownHosts)

        let remaining = try lines(of: knownHosts)
        #expect(remaining == ["host-a key-a", "host-c key-c"])
    }

    @Test func missingFileIsNoOp() throws {
        // No known_hosts file present: must not throw or create one.
        try SSHKnownHostsManager.removeHost(host("host-x key-x"), from: knownHosts)
        #expect(FileManager.default.fileExists(atPath: knownHosts.path) == false)
    }

    @Test func concurrentRemovalsLoseNoOtherEntries() throws {
        // 50 entries; concurrently remove the 25 even-indexed ones. Without the
        // lock, racing read-modify-write cycles would drop unrelated lines.
        let total = 50
        let all = (0..<total).map { "host-\($0) key-\($0)" }
        try (all.joined(separator: "\n") + "\n").write(to: knownHosts, atomically: true, encoding: .utf8)

        let toRemove = stride(from: 0, to: total, by: 2).map { all[$0] }

        DispatchQueue.concurrentPerform(iterations: toRemove.count) { i in
            try? SSHKnownHostsManager.removeHost(host(toRemove[i]), from: knownHosts)
        }

        let remaining = Set(try lines(of: knownHosts))
        let expected = Set(stride(from: 1, to: total, by: 2).map { all[$0] })
        #expect(remaining == expected, "every odd entry must survive; every even entry must be gone")
    }
}
