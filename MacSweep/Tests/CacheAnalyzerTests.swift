import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for `CacheAnalyzer`'s deterministic parse + categorization. These are
/// the pieces that decide what the fast scan reports without any AI call, so they
/// must be exercised directly (the AI path is network-bound and out of scope).
struct CacheAnalyzerTests {

    // MARK: - parseFastScanOutput

    @Test func parseValidTabSeparatedLine() {
        let output = "1.2G\t/Users/x/.npm/_cacache"
        let findings = CacheAnalyzer.parseFastScanOutput(output)
        #expect(findings.count == 1)
        #expect(findings.first?.path == "/Users/x/.npm/_cacache")
        #expect(findings.first?.sizeText == "1.2G")
        #expect(findings.first?.source == "Fast Scan")
        #expect(findings.first?.regeneratesAutomatically == true)
    }

    @Test func parseMultipleLines() {
        let output = "1.2G\t/Users/x/.npm/_cacache\n4.0K\t/Users/x/.cache/uv"
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
        #expect(CacheAnalyzer.parseFastScanOutput("5.0M\t").isEmpty)
    }

    // MARK: - categorize (one representative path per Category)

    @Test func categorizeElectronChromium() {
        #expect(CacheAnalyzer.categorize(path: "/Users/x/Library/Application Support/Slack/Code Cache") == .electronChromium)
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
}
