import Testing
@testable import MacSweepCore

/// Deterministic coverage for the shared Homebrew resolver. The public members
/// hit the real filesystem (install-dependent), so these drive the pure
/// `resolve*` cores with a stubbed existence predicate instead.
struct HomebrewPathsTests {
    @Test func prefersAppleSiliconWhenBothPrefixesExist() {
        let exists: (String) -> Bool = { $0 == "/opt/homebrew/bin/brew" || $0 == "/usr/local/bin/brew" }
        #expect(HomebrewPaths.resolvePrefix(exists: exists) == "/opt/homebrew")
        #expect(HomebrewPaths.resolveBrewPath(exists: exists) == "/opt/homebrew/bin/brew")
    }

    @Test func fallsBackToIntelPrefix() {
        let exists: (String) -> Bool = { $0 == "/usr/local/bin/brew" }
        #expect(HomebrewPaths.resolvePrefix(exists: exists) == "/usr/local")
        #expect(HomebrewPaths.resolveBrewPath(exists: exists) == "/usr/local/bin/brew")
    }

    @Test func returnsNilWhenBrewIsAbsent() {
        let exists: (String) -> Bool = { _ in false }
        #expect(HomebrewPaths.resolvePrefix(exists: exists) == nil)
        #expect(HomebrewPaths.resolveBrewPath(exists: exists) == nil)
        #expect(HomebrewPaths.resolveToolPath("docker", exists: exists) == nil)
    }

    @Test func resolvesToolFromSbinUnderAppleSilicon() {
        let exists: (String) -> Bool = { $0 == "/opt/homebrew/sbin/osx-cpu-temp" }
        #expect(HomebrewPaths.resolveToolPath("osx-cpu-temp", exists: exists) == "/opt/homebrew/sbin/osx-cpu-temp")
    }

    @Test func toolResolutionPrefersBinOverSbinAndAppleSiliconOverIntel() {
        let exists: (String) -> Bool = { _ in true }  // every candidate exists
        #expect(HomebrewPaths.resolveToolPath("docker", exists: exists) == "/opt/homebrew/bin/docker")
    }

    @Test func resolvesIntelToolWhenOnlyIntelPresent() {
        let exists: (String) -> Bool = { $0 == "/usr/local/bin/docker" }
        #expect(HomebrewPaths.resolveToolPath("docker", exists: exists) == "/usr/local/bin/docker")
    }
}
