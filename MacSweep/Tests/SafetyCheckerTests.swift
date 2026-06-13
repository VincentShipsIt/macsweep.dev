import Testing
import Foundation
@testable import MacSweepCore

struct SafetyCheckerTests {
    private let checker = SafetyChecker()

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: - Path traversal

    @Test func traversalEscapeIntoProtectedRootIsBlocked() {
        // `..` segments must be collapsed before evaluation so a cache-rooted
        // path cannot escape into ~/Documents.
        let result = checker.validateForCleanup(url("~/Library/Caches/../../Documents/secret.txt"))
        #expect(!result.isSafe)
    }

    // MARK: - Default-deny

    @Test func unknownPathIsUnsafeByDefault() {
        let result = checker.validateForCleanup(url("~/.m2/repository/org"))
        #expect(!result.isSafe, "Unrecognized paths must default to unsafe")
        if case .unknown = result {} else { Issue.record("Expected .unknown, got \(result)") }
    }

    // MARK: - Module-scoped user-managed carve-outs

    @Test func picturesBlockedForStandardModule() {
        let result = checker.validateForCleanup(
            url("~/Pictures/family-photo.jpg"), moduleID: "system-cache", itemType: .file)
        #expect(!result.isSafe)
    }

    @Test func picturesAllowedForSimilarPhotosCleanup() {
        let result = checker.validateForCleanup(
            url("~/Pictures/similar-shot.jpg"), moduleID: "similar-photos", itemType: .file)
        #expect(result.isSafe)
    }

    @Test func documentsBlockedForLargeFilesCleanup() {
        // large-files may *scan* user-managed roots but never *clean* them.
        let result = checker.validateForCleanup(
            url("~/Documents/project-root"), moduleID: "large-files", itemType: .directory)
        #expect(!result.isSafe)
    }

    @Test func documentsAllowedForLargeFilesScan() {
        let result = checker.validateForScan(url("~/Documents/project-root"), moduleID: "large-files")
        #expect(result.isSafe)
    }

    // MARK: - Longest-prefix arbitration

    @Test func cacheRootAllowed() {
        let result = checker.validateForCleanup(
            url("~/Library/Caches/example-cache"), moduleID: "system-cache", itemType: .directory)
        #expect(result.isSafe)
    }

    @Test func tempFolderAllowed() {
        // /var/folders sits inside the protected /var root; the more-specific
        // safe-cache root must win.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alpha.tmp")
        let result = checker.validateForCleanup(temp, moduleID: "alpha", itemType: .file)
        #expect(result.isSafe)
    }

    @Test func cacheDirNameInsideProtectedRootIsBlocked() {
        // A folder literally named "Cache" inside ~/Documents must still be protected.
        let result = checker.validateForCleanup(url("~/Documents/Cache/x"))
        #expect(!result.isSafe)
    }

    @Test func genericCacheDirNameOutsideProtectedRootAllowed() {
        let result = checker.validateForCleanup(url("~/SomeApp/Cache/x"))
        #expect(result.isSafe)
    }

    // MARK: - Trash allow-zone

    @Test func trashAllowedForTrashModule() {
        let result = checker.validateForCleanup(
            url("~/.Trash/old-file"), moduleID: "trash-bins", itemType: .file)
        #expect(result.isSafe)
    }

    @Test func trashBlockedForNonTrashModule() {
        let result = checker.validateForCleanup(
            url("~/.Trash/old-file"), moduleID: "system-cache", itemType: .file)
        #expect(!result.isSafe)
    }

    // MARK: - Package-manager allow-zone

    @Test func packageManagerCachesAllowedForPackageModule() {
        for path in ["~/.npm/_cacache/abc", "~/Library/pnpm/store/v3", "~/.m2/repository/org"] {
            let result = checker.validateForCleanup(url(path), moduleID: "package-managers", itemType: .directory)
            #expect(result.isSafe, "\(path) should be cleanable by package-managers")
        }
    }

    @Test func packageManagerCachesBlockedForOtherModule() {
        let result = checker.validateForCleanup(
            url("~/.m2/repository/org"), moduleID: "system-cache", itemType: .directory)
        #expect(!result.isSafe)
    }

    // MARK: - Privacy allow-zone

    @Test func privacyArtifactsAllowedForPrivacyModule() {
        let sfl = url("~/Library/Application Support/com.apple.sharedfilelist/x.sfl2")
        #expect(checker.validateForCleanup(sfl, moduleID: "privacy", itemType: .file).isSafe)
        let downloads = url("~/Library/Safari/Downloads.plist")
        #expect(checker.validateForCleanup(downloads, moduleID: "privacy", itemType: .file).isSafe)
    }

    // MARK: - Sensitive patterns block everywhere

    @Test func sensitiveFileBlockedEvenInTrash() {
        let result = checker.validateForCleanup(
            url("~/.Trash/id_rsa"), moduleID: "trash-bins", itemType: .file)
        #expect(!result.isSafe)
    }

    @Test func sensitiveFileBlockedInCache() {
        for path in ["~/Library/Caches/foo.key", "~/Library/Caches/x/cookies.sqlite"] {
            let result = checker.validateForCleanup(url(path), moduleID: "system-cache", itemType: .file)
            #expect(!result.isSafe, "\(path) is sensitive and must be blocked")
        }
    }

    // MARK: - System / credential roots

    @Test func systemRootsBlocked() {
        for path in ["/System/Library/x", "/usr/local/x", "~/.ssh/known_hosts"] {
            #expect(!checker.validateForCleanup(url(path)).isSafe, "\(path) must be protected")
        }
    }

    // MARK: - Generic dev-tool dirs

    @Test func nodeModulesAllowedForDevTools() {
        let result = checker.validateForCleanup(
            url("~/code/app/node_modules"), moduleID: "dev-tools", itemType: .directory)
        #expect(result.isSafe)
    }

    // MARK: - Shred blocklist (validateForShred)

    @Test func shredBlocksFilesystemRoot() {
        #expect(!checker.validateForShred(url("/")).isSafe)
    }

    @Test func shredBlocksHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(!checker.validateForShred(home).isSafe)
    }

    @Test func shredBlocksWholeUserFolders() {
        // The whole ~/Documents (or any user root) is refused, even though files
        // *inside* it are shreddable.
        for path in ["~/Documents", "~/Desktop", "~/Downloads", "~/Pictures", "~/Movies", "~/Music"] {
            let result = checker.validateForShred(url(path))
            #expect(!result.isSafe, "\(path) (whole folder) must be refused")
        }
    }

    @Test func shredBlocksSystemAndCredentialRoots() {
        for path in ["/System/Library/x", "/usr/local/bin/x", "~/.ssh/id_rsa",
                     "~/Library/Preferences/com.apple.foo.plist", "~/Library/Mobile Documents/x"] {
            #expect(!checker.validateForShred(url(path)).isSafe, "\(path) must be refused")
        }
    }

    @Test func shredBlocksTraversalEscapeIntoProtectedRoot() {
        // `..` collapses so a Downloads-rooted path cannot escape into ~/.ssh.
        let result = checker.validateForShred(url("~/Downloads/../.ssh/id_rsa"))
        #expect(!result.isSafe)
    }

    @Test func shredAllowsFilesInsideUserFolders() {
        // Files the user explicitly drops in — including credential files they
        // want destroyed — are shreddable when nested inside a user root.
        for path in ["~/Downloads/secret.key", "~/Documents/old_tax.pdf", "~/Desktop/a/b/c.bin"] {
            #expect(checker.validateForShred(url(path)).isSafe, "\(path) should be shreddable")
        }
    }

    @Test func shredAllowsArbitraryNonProtectedFiles() {
        for path in ["/tmp/macsweep/junk.bin", "~/code/proj/build/out.o"] {
            #expect(checker.validateForShred(url(path)).isSafe, "\(path) should be shreddable")
        }
    }

    @Test func shredRefusesSymlink() throws {
        // A symlink must be refused: overwriting would destroy its target.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsweep-shred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("real.txt")
        try Data("data".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = checker.validateForShred(link)
        #expect(!result.isSafe)
        if case .symlink = result {} else { Issue.record("Expected .symlink, got \(result)") }
    }
}
