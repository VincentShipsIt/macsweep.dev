import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for `LoginItemEnumerator.parseSfltoolOutput`, the pure text parser for
/// `sfltool dumpbtm`. The subprocess itself is root-only and non-deterministic, so
/// these feed it synthetic dump text and assert the entry-extraction logic:
/// well-formed blocks, the `executableURL =` spelling variant, `file://` stripping,
/// and the failure modes (missing closing brace, no path, empty input) that must
/// yield no phantom login items.
///
/// `LoginItemEnumerator` is an actor, so the parser is reached via `await`.
struct LoginItemEnumeratorTests {
    private let enumerator = LoginItemEnumerator()

    @Test func parsesWellFormedEntryWithFileURL() async {
        let output = """
        {
            name = "Spotify"
            bundleIdentifier = "com.spotify.client"
            url = "file:///Applications/Spotify.app"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.count == 1)
        #expect(items.first?.name == "Spotify")
        // file:// prefix stripped, leaving an absolute path.
        #expect(items.first?.path == "/Applications/Spotify.app")
        #expect(items.first?.bundleIdentifier == "com.spotify.client")
        #expect(items.first?.kind == .appService)
        #expect(items.first?.enabled == true)
    }

    @Test func parsesExecutableURLVariant() async {
        // Some entries spell the location `executableURL = …` instead of `url = …`;
        // both must resolve to the same path field.
        let output = """
        {
            name = "BackupHelper"
            executableURL = "file:///Applications/Backup.app/Contents/MacOS/helper"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.count == 1)
        #expect(items.first?.path == "/Applications/Backup.app/Contents/MacOS/helper")
    }

    @Test func parsesMultipleEntries() async {
        let output = """
        {
            name = "First"
            url = "file:///Applications/First.app"
        },
        {
            name = "Second"
            url = "file:///Applications/Second.app"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.count == 2)
        #expect(items.map(\.name) == ["First", "Second"])
    }

    @Test func skipsEntryMissingClosingBrace() async {
        // No `}` ever flushes the accumulated name/url, so a truncated final block
        // is dropped rather than emitted half-populated.
        let output = """
        {
            name = "Truncated"
            url = "file:///Applications/Truncated.app"
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.isEmpty)
    }

    @Test func skipsEntryWithoutPath() async {
        // A block with a name but no url/executableURL is not a usable login item.
        let output = """
        {
            name = "NameOnly"
            bundleIdentifier = "com.example.nopath"
        }
        """
        let items = await enumerator.parseSfltoolOutput(output)
        #expect(items.isEmpty)
    }

    @Test func parsesEmptyInputToNothing() async {
        #expect(await enumerator.parseSfltoolOutput("").isEmpty)
    }
}
