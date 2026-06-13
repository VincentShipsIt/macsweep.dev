import Testing
import Foundation
@testable import MacSweepCore

// Coverage for the disposal primitive every cleanup module routes through.
// `permanent` is fully deterministic. `recoverable` (Trash) is exercised on the
// happy path and the missing-item path; trashItem works headlessly on macOS, but
// the assertions only require the source to be gone, not where it landed.
//
// final class: init()/deinit give per-test setUp/tearDown of a UUID-scoped temp
// dir so parallel @Test instances can't collide.
final class CleanupFileRemoverTests {

    let testDirectory: URL

    init() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepRemoverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    // MARK: - permanent

    @Test func permanentDeletesFile() throws {
        let file = testDirectory.appendingPathComponent("junk.cache")
        try Data("regenerable".utf8).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))

        try CleanupFileRemover.permanent(file)

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func permanentDeletesDirectoryRecursively() throws {
        let dir = testDirectory.appendingPathComponent("cache-tree")
        let nested = dir.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("leaf.bin"))

        try CleanupFileRemover.permanent(dir)

        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func permanentThrowsOnMissingItem() {
        let missing = testDirectory.appendingPathComponent("never-existed.bin")
        #expect(throws: (any Error).self) {
            try CleanupFileRemover.permanent(missing)
        }
    }

    // MARK: - recoverable (Trash)

    @Test func recoverableRemovesItemFromOriginalLocation() throws {
        let file = testDirectory.appendingPathComponent("regrettable.txt")
        try Data("user might want this back".utf8).write(to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))

        try CleanupFileRemover.recoverable(file)

        // The whole point: it leaves the original location (it's now in Trash).
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func recoverableThrowsOnMissingItem() {
        let missing = testDirectory.appendingPathComponent("not-here.txt")
        #expect(throws: (any Error).self) {
            try CleanupFileRemover.recoverable(missing)
        }
    }
}
