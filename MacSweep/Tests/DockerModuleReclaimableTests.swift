import Foundation
import Testing
@testable import MacSweepCore

/// Regression tests for #80: Docker cleanup items are now sized by real
/// reclaimable bytes parsed from `docker system df`, so dry-run estimates and
/// DeletionGuard see truth instead of a synthetic 0.
struct DockerModuleReclaimableTests {
    private func df(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test func parsesReclaimablePerType() {
        let data = df([
            #"{"Active":"2","Reclaimable":"1.2GB (80%)","Size":"1.5GB","TotalCount":"10","Type":"Images"}"#,
            #"{"Active":"1","Reclaimable":"0B","Size":"0B","TotalCount":"3","Type":"Containers"}"#,
            #"{"Active":"0","Reclaimable":"512MB (100%)","Size":"512MB","TotalCount":"2","Type":"Local Volumes"}"#,
            #"{"Active":"0","Reclaimable":"256MB","Size":"256MB","TotalCount":"5","Type":"Build Cache"}"#,
        ])

        let result = DockerModule.parseReclaimableByType(data)

        #expect(result["Images"] == Int64(1.2 * 1_000_000_000))
        #expect(result["Containers"] == 0)
        #expect(result["Local Volumes"] == Int64(512 * 1_000_000))
        #expect(result["Build Cache"] == Int64(256 * 1_000_000))
    }

    @Test func emptyOutputYieldsNoEntries() {
        #expect(DockerModule.parseReclaimableByType(Data()).isEmpty)
    }

    @Test func malformedLinesAreSkipped() {
        let data = df([
            "not json",
            #"{"Type":"Images"}"#,                                   // missing Reclaimable
            #"{"Reclaimable":"1GB"}"#,                               // missing Type
            #"{"Reclaimable":"2GB (50%)","Type":"Build Cache"}"#,   // valid
        ])

        let result = DockerModule.parseReclaimableByType(data)
        #expect(result.count == 1)
        #expect(result["Build Cache"] == Int64(2 * 1_000_000_000))
    }

    @Test func invalidOrOutOfRangeSizesFailClosedWithoutTrapping() {
        #expect(DockerCLI.parseBytes("-1GB") == 0)
        #expect(DockerCLI.parseBytes("999999999999999999999999GB") == 0)
        #expect(DockerCLI.parseBytes("not-a-size") == 0)
        #expect(DockerCLI.parseBytes("12XB") == 0)
        #expect(DockerCLI.parseBytes("12") == 0)
        #expect(DockerCLI.parseBytes("1e3GB") == 0)
        #expect(DockerCLI.parseBytes("1..2GB") == 0)
        #expect(DockerCLI.parseBytes("NaNGB") == 0)
    }

    @Test func parsesSupportedDockerAndExplicitBareOrIECUnits() {
        let cases: [(input: String, expected: Int64)] = [
            ("1B", 1),
            ("1kB", 1_000),
            ("1MB", 1_000_000),
            ("1GB", 1_000_000_000),
            ("1TB", 1_000_000_000_000),
            ("1PB", 1_000_000_000_000_000),
            ("1K", 1_000),
            ("1M", 1_000_000),
            ("1G", 1_000_000_000),
            ("1T", 1_000_000_000_000),
            ("1P", 1_000_000_000_000_000),
            ("1KiB", 1_024),
            ("1MiB", 1_048_576),
            ("1GiB", 1_073_741_824),
            ("1TiB", 1_099_511_627_776),
            ("1PiB", 1_125_899_906_842_624),
        ]

        for testCase in cases {
            #expect(DockerCLI.parseBytes(testCase.input) == testCase.expected)
        }
    }
}
