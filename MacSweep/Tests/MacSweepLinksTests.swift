import Testing
@testable import MacSweepCore

struct MacSweepLinksTests {
    @Test func websiteUsesTheOfficialProductDomain() {
        #expect(MacSweepLinks.website.absoluteString == "https://macsweep.dev")
        #expect(MacSweepLinks.websiteDisplayName == "macsweep.dev")
    }

    @Test func repositoryUsesTheCurrentGitHubSlug() {
        #expect(
            MacSweepLinks.repository.absoluteString
                == "https://github.com/VincentShipsIt/macsweep.dev"
        )
    }
}
