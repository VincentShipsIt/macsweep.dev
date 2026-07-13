import Testing
import Foundation
@testable import MacSweepCore

/// Coverage for `UpdateChannel`, the Sparkle channel selector behind the
/// Settings ▸ General "Update channel" picker. Each test runs against an
/// isolated `UserDefaults` suite so it never touches the real `dev.macsweep`
/// domain, and tears the suite down in `deinit`.
final class UpdateChannelTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        suiteName = "MacSweepUpdateChannelTests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Version-derived defaults

    @Test func releaseVersionsDefaultToStable() {
        #expect(UpdateChannel.defaultChannel(forVersion: "1.1.1") == .stable)
        #expect(UpdateChannel.defaultChannel(forVersion: "2.0.0") == .stable)
    }

    @Test func nightlyVersionsDefaultToNightly() {
        #expect(UpdateChannel.defaultChannel(forVersion: "1.1.1-nightly.20260713") == .nightly)
    }

    @Test func resolvedFallsBackToVersionDefaultWhenNothingStored() {
        #expect(UpdateChannel.resolved(defaults: defaults, currentVersion: "1.1.1") == .stable)
        #expect(
            UpdateChannel.resolved(defaults: defaults, currentVersion: "1.1.1-nightly.20260713")
                == .nightly
        )
    }

    // MARK: - Stored user choice

    @Test func storedChoiceOverridesVersionDefault() {
        defaults.set(UpdateChannel.nightly.rawValue, forKey: UpdateChannel.defaultsKey)
        #expect(UpdateChannel.resolved(defaults: defaults, currentVersion: "1.1.1") == .nightly)

        defaults.set(UpdateChannel.stable.rawValue, forKey: UpdateChannel.defaultsKey)
        #expect(
            UpdateChannel.resolved(defaults: defaults, currentVersion: "1.1.1-nightly.20260713")
                == .stable
        )
    }

    @Test func invalidStoredValueFallsBackToVersionDefault() {
        defaults.set("beta", forKey: UpdateChannel.defaultsKey)
        #expect(UpdateChannel.resolved(defaults: defaults, currentVersion: "1.1.1") == .stable)
    }

    // MARK: - Feed URLs

    @Test func stableUsesTheInfoPlistFeed() {
        // nil = Sparkle falls back to SUFeedURL, the production appcast.
        #expect(UpdateChannel.stable.feedURLString == nil)
    }

    @Test func nightlyReadsTheRollingNightlyRelease() {
        #expect(
            UpdateChannel.nightly.feedURLString
                == "https://github.com/VincentShipsIt/macsweep.dev/releases/download/nightly/appcast.xml"
        )
    }
}
