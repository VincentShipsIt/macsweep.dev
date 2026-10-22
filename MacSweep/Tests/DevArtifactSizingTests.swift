import Foundation
import Testing

@testable import MacSweepCore

struct DevArtifactSizingTests {
    @Test func artifactSizingIsBoundedAndDoesNotFollowDependencyLinks() throws {
        let temp = try TempTestDirectory(prefix: "ArtifactSizing")
        let root = temp.url
        let target = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: target.appendingPathComponent("generated.bin"))
        let outside = root.appendingPathComponent("user-data")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: outside.appendingPathComponent("private.bin"))
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("shared"), withDestinationURL: outside)
        let measured = try DevArtifactContent.measure(target)
        #expect(measured.size == 4096)
        #expect(throws: DevArtifactSafetyError.self) {
            try DevArtifactContent.measure(target, maximumEntries: 1)
        }
        #expect(throws: DevArtifactSafetyError.self) {
            try DevArtifactContent.measure(target, deadline: ProcessInfo.processInfo.systemUptime - 1)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("private.bin").path))
    }

}
