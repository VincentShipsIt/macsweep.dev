import XCTest
@testable import MacSweepCore

final class SafetyCheckerTests: XCTestCase {
    private let checker = SafetyChecker()

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: - Path traversal

    func testTraversalEscapeIntoProtectedRootIsBlocked() {
        // `..` segments must be collapsed before evaluation so a cache-rooted
        // path cannot escape into ~/Documents.
        let result = checker.validateForCleanup(url("~/Library/Caches/../../Documents/secret.txt"))
        XCTAssertFalse(result.isSafe)
    }

    // MARK: - Default-deny

    func testUnknownPathIsUnsafeByDefault() {
        let result = checker.validateForCleanup(url("~/.m2/repository/org"))
        XCTAssertFalse(result.isSafe, "Unrecognized paths must default to unsafe")
        if case .unknown = result {} else { XCTFail("Expected .unknown, got \(result)") }
    }

    // MARK: - Module-scoped user-managed carve-outs

    func testPicturesBlockedForStandardModule() {
        let result = checker.validateForCleanup(
            url("~/Pictures/family-photo.jpg"), moduleID: "system-cache", itemType: .file)
        XCTAssertFalse(result.isSafe)
    }

    func testPicturesAllowedForSimilarPhotosCleanup() {
        let result = checker.validateForCleanup(
            url("~/Pictures/similar-shot.jpg"), moduleID: "similar-photos", itemType: .file)
        XCTAssertTrue(result.isSafe)
    }

    func testDocumentsBlockedForLargeFilesCleanup() {
        // large-files may *scan* user-managed roots but never *clean* them.
        let result = checker.validateForCleanup(
            url("~/Documents/project-root"), moduleID: "large-files", itemType: .directory)
        XCTAssertFalse(result.isSafe)
    }

    func testDocumentsAllowedForLargeFilesScan() {
        let result = checker.validateForScan(url("~/Documents/project-root"), moduleID: "large-files")
        XCTAssertTrue(result.isSafe)
    }

    // MARK: - Longest-prefix arbitration

    func testCacheRootAllowed() {
        let result = checker.validateForCleanup(
            url("~/Library/Caches/example-cache"), moduleID: "system-cache", itemType: .directory)
        XCTAssertTrue(result.isSafe)
    }

    func testTempFolderAllowed() {
        // /var/folders sits inside the protected /var root; the more-specific
        // safe-cache root must win.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("alpha.tmp")
        let result = checker.validateForCleanup(temp, moduleID: "alpha", itemType: .file)
        XCTAssertTrue(result.isSafe)
    }

    func testCacheDirNameInsideProtectedRootIsBlocked() {
        // A folder literally named "Cache" inside ~/Documents must still be protected.
        let result = checker.validateForCleanup(url("~/Documents/Cache/x"))
        XCTAssertFalse(result.isSafe)
    }

    func testGenericCacheDirNameOutsideProtectedRootAllowed() {
        let result = checker.validateForCleanup(url("~/SomeApp/Cache/x"))
        XCTAssertTrue(result.isSafe)
    }

    // MARK: - Trash allow-zone

    func testTrashAllowedForTrashModule() {
        let result = checker.validateForCleanup(
            url("~/.Trash/old-file"), moduleID: "trash-bins", itemType: .file)
        XCTAssertTrue(result.isSafe)
    }

    func testTrashBlockedForNonTrashModule() {
        let result = checker.validateForCleanup(
            url("~/.Trash/old-file"), moduleID: "system-cache", itemType: .file)
        XCTAssertFalse(result.isSafe)
    }

    // MARK: - Package-manager allow-zone

    func testPackageManagerCachesAllowedForPackageModule() {
        for path in ["~/.npm/_cacache/abc", "~/Library/pnpm/store/v3", "~/.m2/repository/org"] {
            let result = checker.validateForCleanup(url(path), moduleID: "package-managers", itemType: .directory)
            XCTAssertTrue(result.isSafe, "\(path) should be cleanable by package-managers")
        }
    }

    func testPackageManagerCachesBlockedForOtherModule() {
        let result = checker.validateForCleanup(
            url("~/.m2/repository/org"), moduleID: "system-cache", itemType: .directory)
        XCTAssertFalse(result.isSafe)
    }

    // MARK: - Privacy allow-zone

    func testPrivacyArtifactsAllowedForPrivacyModule() {
        let sfl = url("~/Library/Application Support/com.apple.sharedfilelist/x.sfl2")
        XCTAssertTrue(checker.validateForCleanup(sfl, moduleID: "privacy", itemType: .file).isSafe)
        let downloads = url("~/Library/Safari/Downloads.plist")
        XCTAssertTrue(checker.validateForCleanup(downloads, moduleID: "privacy", itemType: .file).isSafe)
    }

    // MARK: - Sensitive patterns block everywhere

    func testSensitiveFileBlockedEvenInTrash() {
        let result = checker.validateForCleanup(
            url("~/.Trash/id_rsa"), moduleID: "trash-bins", itemType: .file)
        XCTAssertFalse(result.isSafe)
    }

    func testSensitiveFileBlockedInCache() {
        for path in ["~/Library/Caches/foo.key", "~/Library/Caches/x/cookies.sqlite"] {
            let result = checker.validateForCleanup(url(path), moduleID: "system-cache", itemType: .file)
            XCTAssertFalse(result.isSafe, "\(path) is sensitive and must be blocked")
        }
    }

    // MARK: - System / credential roots

    func testSystemRootsBlocked() {
        for path in ["/System/Library/x", "/usr/local/x", "~/.ssh/known_hosts"] {
            XCTAssertFalse(checker.validateForCleanup(url(path)).isSafe, "\(path) must be protected")
        }
    }

    // MARK: - Generic dev-tool dirs

    func testNodeModulesAllowedForDevTools() {
        let result = checker.validateForCleanup(
            url("~/code/app/node_modules"), moduleID: "dev-tools", itemType: .directory)
        XCTAssertTrue(result.isSafe)
    }

    // MARK: - Shred blocklist (validateForShred)

    func testShredBlocksFilesystemRoot() {
        XCTAssertFalse(checker.validateForShred(url("/")).isSafe)
    }

    func testShredBlocksHomeDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertFalse(checker.validateForShred(home).isSafe)
    }

    func testShredBlocksWholeUserFolders() {
        // The whole ~/Documents (or any user root) is refused, even though files
        // *inside* it are shreddable.
        for path in ["~/Documents", "~/Desktop", "~/Downloads", "~/Pictures", "~/Movies", "~/Music"] {
            let result = checker.validateForShred(url(path))
            XCTAssertFalse(result.isSafe, "\(path) (whole folder) must be refused")
        }
    }

    func testShredBlocksSystemAndCredentialRoots() {
        for path in ["/System/Library/x", "/usr/local/bin/x", "~/.ssh/id_rsa",
                     "~/Library/Preferences/com.apple.foo.plist", "~/Library/Mobile Documents/x"] {
            XCTAssertFalse(checker.validateForShred(url(path)).isSafe, "\(path) must be refused")
        }
    }

    func testShredBlocksTraversalEscapeIntoProtectedRoot() {
        // `..` collapses so a Downloads-rooted path cannot escape into ~/.ssh.
        let result = checker.validateForShred(url("~/Downloads/../.ssh/id_rsa"))
        XCTAssertFalse(result.isSafe)
    }

    func testShredAllowsFilesInsideUserFolders() {
        // Files the user explicitly drops in — including credential files they
        // want destroyed — are shreddable when nested inside a user root.
        for path in ["~/Downloads/secret.key", "~/Documents/old_tax.pdf", "~/Desktop/a/b/c.bin"] {
            XCTAssertTrue(checker.validateForShred(url(path)).isSafe, "\(path) should be shreddable")
        }
    }

    func testShredAllowsArbitraryNonProtectedFiles() {
        for path in ["/tmp/macsweep/junk.bin", "~/code/proj/build/out.o"] {
            XCTAssertTrue(checker.validateForShred(url(path)).isSafe, "\(path) should be shreddable")
        }
    }

    func testShredRefusesSymlink() throws {
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
        XCTAssertFalse(result.isSafe)
        if case .symlink = result {} else { XCTFail("Expected .symlink, got \(result)") }
    }
}
