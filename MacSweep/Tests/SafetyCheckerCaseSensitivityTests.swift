import Testing
import Foundation
@testable import MacSweepCore

/// Regression coverage for a case-sensitivity gap in `SafetyChecker`.
///
/// The default macOS boot volume is APFS **case-insensitive**, so `~/documents`
/// and `~/Documents` (or `~/.SSH` and `~/.ssh`) resolve to the same on-disk
/// directory. But `SafetyChecker` compares paths against its protected-root
/// lists with raw, case-sensitive `==` / `hasPrefix` (see `isUnder`,
/// `longestPrefixLength`, and the whole-user-folder guard in
/// `validateBlocklist`). A case-variant of a protected root therefore matches
/// *none* of the protected entries.
///
/// Impact splits by mode:
///   • Cleanup (default-deny): a case-variant falls through to `.unknown` and is
///     denied — fails safe. Asserted below as current, correct behavior.
///   • Shred / explicit-Trash (blocklist, unrecognized == allowed): a
///     case-variant of a protected root passes the blocklist and would be
///     shredded/trashed — fails OPEN. That is the defect.
///
/// FIXED in the same PR that removed the `withKnownIssue` wrappers these once
/// carried: `SafetyChecker` now normalizes case per the boot volume's regime, so
/// on a case-INSENSITIVE volume a case-variant of a protected root matches it.
///
/// The blocklist assertions below only make sense on a case-INSENSITIVE volume:
/// there `~/.SSH` and `~/.ssh` are the same directory, so shredding one must be
/// refused. On a genuinely case-SENSITIVE volume they are distinct paths and the
/// shredder is *correct* to allow the variant — so those three assertions are
/// gated on the host volume (a no-op on the rare case-sensitive host). The macOS
/// default boot volume, and the CI runners, are case-insensitive APFS, so the
/// real assertions run there.
///
/// Tracked in issue #122.
struct SafetyCheckerCaseSensitivityTests {
    private let checker = SafetyChecker()
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// True when the volume backing `~` folds case (the macOS default). Mirrors
    /// `SafetyChecker`'s own volume probe; the blocklist scenarios only apply here.
    private var homeVolumeIsCaseInsensitive: Bool {
        let values = try? home.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return !(values?.volumeSupportsCaseSensitiveNames ?? true)
    }

    // MARK: - Cleanup mode: case-variant fails safe (default-deny). Host-independent.

    @Test func cleanupCaseVariantOfUserRootIsNotSafe() {
        // ~/documents (lowercase) under the large-files module: default-deny means
        // an unrecognized case-variant is refused for automated cleanup. This holds
        // on any host — a case-sensitive volume denies it as unknown, a
        // case-insensitive volume now denies it as a protected ~/Documents match.
        let variant = home.appendingPathComponent("documents")
        let result = checker.validateForCleanup(variant, moduleID: "large-files", itemType: .directory)
        #expect(!result.isSafe, "Automated cleanup must not treat a case-variant of ~/Documents as safe")
    }

    // MARK: - Shred/Trash blocklist: case-variant of a protected root is refused.

    @Test func shredCaseVariantOfWholeUserFolderIsRefused() {
        // ~/documents == ~/Documents on a case-insensitive volume; shredding the
        // whole user folder must be refused.
        guard homeVolumeIsCaseInsensitive else { return }
        let variant = home.appendingPathComponent("documents")
        let result = checker.validateForShred(variant)
        #expect(!result.isSafe, "Shredding a case-variant of an entire user folder must be refused")
    }

    @Test func shredCaseVariantOfCredentialRootIsRefused() {
        // ~/.SSH == ~/.ssh on a case-insensitive volume; shredding the SSH key
        // directory must be refused.
        guard homeVolumeIsCaseInsensitive else { return }
        let variant = home.appendingPathComponent(".SSH")
        let result = checker.validateForShred(variant)
        #expect(!result.isSafe, "Shredding a case-variant of ~/.ssh must be refused")
    }

    @Test func trashCaseVariantOfCredentialRootIsRefused() {
        // Same gap via the explicit move-to-Trash blocklist (Space Lens).
        guard homeVolumeIsCaseInsensitive else { return }
        let variant = home.appendingPathComponent(".AWS")
        let result = checker.validateForTrash(variant)
        #expect(!result.isSafe, "Trashing a case-variant of ~/.aws must be refused")
    }
}
