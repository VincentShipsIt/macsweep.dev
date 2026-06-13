import Testing
import Foundation
@testable import MacSweepCLIKit
@testable import MacSweepCore

struct CLICommandParserTests {
    @Test func parsesSmartCareDryRunAsJson() throws {
        let command = try CLICommandParser.parse([
            "dry-run",
            "--smart-care",
            "--format", "json",
        ])

        #expect(command == .dryRun(HeadlessSelectionRequest(moduleIDs: nil, smartCare: true), .json))
    }

    @Test func parsesApplyWithModulesAndYes() throws {
        let command = try CLICommandParser.parse([
            "apply",
            "--modules", "system-cache,trash-bins",
            "--yes",
        ])

        #expect(command == .apply(
            HeadlessSelectionRequest(moduleIDs: ["system-cache", "trash-bins"], smartCare: false),
            yes: true,
            format: .text
        ))
    }

    @Test func rejectsUnknownFormat() {
        #expect(throws: (any Error).self) {
            try CLICommandParser.parse(["scan", "--format", "xml"])
        }
    }
}
