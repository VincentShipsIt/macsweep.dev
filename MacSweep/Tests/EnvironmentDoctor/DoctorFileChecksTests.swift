import Foundation
import Testing

@testable import MacSweepCore

struct DoctorFileChecksTests {
    @Test func cleanFixtureProducesNoFileFindings() throws {
        let temp = try TempTestDirectory(prefix: "DoctorClean")
        let agents = temp.url.appendingPathComponent("Library/LaunchAgents")
        let bin = temp.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("tool")
        try Data([1]).write(to: tool)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("working"), withDestinationURL: tool)
        try writePlist(agents.appendingPathComponent("valid.plist"), ["Program": tool.path])
        let paths = DoctorPaths(home: temp.url, launchDirectories: [agents], binDirectories: [bin], brew: nil)
        let report = try DoctorFileChecks.scan(paths, checker: SafetyChecker())
        #expect(report.findings.isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test func exactMissingProgramsAndBrokenLinksHaveIndependentEvidence() throws {
        let temp = try TempTestDirectory(prefix: "DoctorMissing")
        let agents = temp.url.appendingPathComponent("Library/LaunchAgents")
        let bin = temp.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let missing = temp.url.appendingPathComponent("missing-tool")
        try writePlist(agents.appendingPathComponent("orphan.plist"), ["ProgramArguments": [missing.path, "--service"]])
        try writePlist(agents.appendingPathComponent("relative.plist"), ["Program": "tool"])
        try FileManager.default.createSymbolicLink(
            atPath: bin.appendingPathComponent("broken").path,
            withDestinationPath: "../missing-tool")
        let paths = DoctorPaths(home: temp.url, launchDirectories: [agents], binDirectories: [bin], brew: nil)
        let report = try DoctorFileChecks.scan(paths, checker: SafetyChecker())
        #expect(report.findings.count == 2)
        #expect(
            report.findings.first { $0.category == .launchItems }?.repair == .orphanedLaunchItem(program: missing.path))
        #expect(report.findings.first { $0.category == .links }?.repair == .brokenLink(destination: "../missing-tool"))
        for finding in report.findings {
            #expect(
                finding.canRepair,
                "\(finding.path?.path ?? "no path"): \(finding.retentionReason ?? "no retention reason")")
        }
    }

    @Test func linkedCheckRootsNeverWalkIntoOtherDirectories() throws {
        let temp = try TempTestDirectory(prefix: "DoctorLinked")
        let actual = temp.url.appendingPathComponent("actual")
        let linked = temp.url.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        try writePlist(actual.appendingPathComponent("would-be-orphan.plist"), ["Program": "/missing"])
        let report = try DoctorFileChecks.scan(
            DoctorPaths(
                home: temp.url, launchDirectories: [linked],
                binDirectories: [], brew: nil), checker: SafetyChecker())
        #expect(report.findings.isEmpty)
        #expect(!report.issues.isEmpty)
    }

    @Test func pathCheckDistinguishesDeadDuplicateAndRelativeEntries() throws {
        let temp = try TempTestDirectory(prefix: "DoctorPATH")
        let path = temp.url.path
        let source = temp.url.appendingPathComponent(".zprofile")
        let report = DoctorCommandChecks.inspectPath(
            "\(path):\(path):\(path)/missing:.",
            sources: [(source, "export PATH=\"\(path):\(path)/missing:$PATH\"")])
        #expect(report.findings.count == 3)
        #expect(report.findings.contains { $0.evidence.contains("Duplicate") })
        #expect(
            report.findings.contains { $0.evidence.contains("does not exist") && $0.evidence.contains(".zprofile:1") })
        #expect(report.findings.contains { $0.evidence.contains("Relative") })
        #expect(report.findings.allSatisfy { !$0.canRepair && $0.remediation.contains("never edits") })
    }

    @Test func homebrewCleanWarningsAndFailuresRemainDistinct() {
        #expect(
            DoctorCommandChecks.parseHomebrew(
                ProcessResult(
                    status: 0,
                    output: "Your system is ready to brew.", error: "")
            ).findings.isEmpty)
        let warning = DoctorCommandChecks.parseHomebrew(
            ProcessResult(
                status: 1,
                output: "", error: "Warning: Broken symlinks\nRemove the broken link."))
        #expect(warning.findings.count == 1)
        #expect(warning.findings.first?.canRepair == false)
        #expect(warning.findings.first?.evidence.contains("Broken symlinks") == true)
        #expect(!DoctorCommandChecks.parseHomebrew(ProcessResult(status: 1, output: "", error: "")).issues.isEmpty)
    }

    private func writePlist(_ path: URL, _ content: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0).write(to: path)
    }
}
