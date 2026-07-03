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
/// The shred/trash expectations use `withKnownIssue` so the suite stays green
/// while the bug is open. When the fix lands (case-fold both sides, or resolve
/// to a canonical inode before comparing), `withKnownIssue` will start failing
/// with "known issue was not recorded" — the signal to delete these wrappers.
///
/// These checks are filesystem-independent: `SafetyChecker` decides via string
/// comparison, so the result does not depend on `~/.ssh` or `~/documents`
/// actually existing on the test host.
///
/// Tracked in issue #122.
struct SafetyCheckerCaseSensitivityTests {
    private let checker = SafetyChecker()
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - Cleanup mode: case-variant fails safe (default-deny). Passes today.

    @Test func cleanupCaseVariantOfUserRootIsNotSafe() {
        // ~/documents (lowercase) under the large-files module: default-deny means
        // an unrecognized case-variant is refused for automated cleanup.
        let variant = home.appendingPathComponent("documents")
        let result = checker.validateForCleanup(variant, moduleID: "large-files", itemType: .directory)
        #expect(!result.isSafe, "Automated cleanup must not treat a case-variant of ~/Documents as safe")
    }

    // MARK: - Shred/Trash blocklist: case-variant currently fails OPEN. Known bug.

    @Test func shredCaseVariantOfWholeUserFolderIsRefused() {
        // ~/documents == ~/Documents on a case-insensitive volume; shredding the
        // whole user folder must be refused. Currently allowed → known issue.
        let variant = home.appendingPathComponent("documents")
        withKnownIssue("SafetyChecker case-sensitive compare bypasses whole-user-folder guard on case-insensitive APFS (issue #122)") {
            let result = checker.validateForShred(variant)
            #expect(!result.isSafe, "Shredding a case-variant of an entire user folder must be refused")
        }
    }

    @Test func shredCaseVariantOfCredentialRootIsRefused() {
        // ~/.SSH == ~/.ssh on a case-insensitive volume; shredding the SSH key
        // directory must be refused. Currently allowed → known issue.
        let variant = home.appendingPathComponent(".SSH")
        withKnownIssue("SafetyChecker case-sensitive compare bypasses neverDelete credential root on case-insensitive APFS (issue #122)") {
            let result = checker.validateForShred(variant)
            #expect(!result.isSafe, "Shredding a case-variant of ~/.ssh must be refused")
        }
    }

    @Test func trashCaseVariantOfCredentialRootIsRefused() {
        // Same gap via the explicit move-to-Trash blocklist (Space Lens).
        let variant = home.appendingPathComponent(".AWS")
        withKnownIssue("SafetyChecker case-sensitive compare bypasses neverDelete credential root for explicit Trash (issue #122)") {
            let result = checker.validateForTrash(variant)
            #expect(!result.isSafe, "Trashing a case-variant of ~/.aws must be refused")
        }
    }
}
