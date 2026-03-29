import XCTest
@testable import MacSweepCLIKit
@testable import MacSweepCore

final class CLICommandParserTests: XCTestCase {
    func testParsesSmartCareDryRunAsJson() throws {
        let command = try CLICommandParser.parse([
            "dry-run",
            "--smart-care",
            "--format", "json",
        ])

        XCTAssertEqual(
            command,
            .dryRun(HeadlessSelectionRequest(moduleIDs: nil, smartCare: true), .json)
        )
    }

    func testParsesApplyWithModulesAndYes() throws {
        let command = try CLICommandParser.parse([
            "apply",
            "--modules", "system-cache,trash-bins",
            "--yes",
        ])

        XCTAssertEqual(
            command,
            .apply(
                HeadlessSelectionRequest(moduleIDs: ["system-cache", "trash-bins"], smartCare: false),
                yes: true,
                format: .text
            )
        )
    }

    func testRejectsUnknownFormat() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["scan", "--format", "xml"])
        )
    }
}
