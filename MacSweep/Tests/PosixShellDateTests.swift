import Foundation
import Testing
@testable import MacSweepCore

/// Coverage for `DateFormatter.posixShellDate(format:)` — the shared helper that
/// `AppUninstallerModule` (mdls `kMDItemLastUsedDate`) and
/// `DevToolsModule.parseGitDate` (git `%cI`) both use to parse fixed-format shell
/// timestamps. Issue #87: the AppUninstaller parser previously omitted the POSIX
/// locale, so "last used" dates blanked out on 12-hour / non-Gregorian locales.
struct PosixShellDateTests {
    private static let shellFormat = "yyyy-MM-dd HH:mm:ss Z"

    @Test func pinsPOSIXLocale() {
        let formatter = DateFormatter.posixShellDate(format: Self.shellFormat)
        #expect(formatter.locale.identifier == "en_US_POSIX")
        #expect(formatter.dateFormat == Self.shellFormat)
    }

    @Test func parses24HourTimestampToStableInstant() {
        let formatter = DateFormatter.posixShellDate(format: Self.shellFormat)
        let parsed = formatter.date(from: "2024-01-15 10:30:00 +0000")
        // 2024-01-15 10:30:00 UTC == 1705314600 (epoch seconds).
        #expect(parsed?.timeIntervalSince1970 == 1_705_314_600)
    }

    /// The POSIX helper parses a 24-hour hour field (`13`) unambiguously.
    /// A formatter whose calendar/locale expects a 12-hour clock would reject a
    /// bare 24-hour value — the divergence issue #87 removes.
    @Test func parses24HourAfternoonField() {
        let formatter = DateFormatter.posixShellDate(format: Self.shellFormat)
        let parsed = formatter.date(from: "2024-06-01 13:45:00 +0000")
        #expect(parsed != nil)
        #expect(parsed?.timeIntervalSince1970 == 1_717_249_500)
    }
}
