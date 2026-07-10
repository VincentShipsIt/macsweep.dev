import Darwin
import Foundation
import Testing
@testable import MacSweepCore

final class SecureDeleteDirectoryTests {

    private struct InjectedOverwriteFailure: LocalizedError {
        let url: URL

        var errorDescription: String? {
            "Injected overwrite failure for \(url.lastPathComponent)"
        }
    }

    private let temp: TempTestDirectory
    private let root: URL

    init() throws {
        temp = try TempTestDirectory(prefix: "SecureDeleteDirectoryTests")
        root = temp.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @Test func failedFileRemainsWhileSuccessfulSiblingIsRemoved() async throws {
        let successful = root.appendingPathComponent("successful.txt")
        let failed = root.appendingPathComponent("failed.txt")
        try Data("removed".utf8).write(to: successful)
        try Data("must remain".utf8).write(to: failed)

        let result = try await shredDirectory(failing: [failed.lastPathComponent])

        #expect(!FileManager.default.fileExists(atPath: successful.path))
        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(try Data(contentsOf: failed) == Data("partially overwritten".utf8))
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(result.filesShredded == 1)
        #expect(result.bytesShredded == Int64(Data("removed".utf8).count))
        #expect(!result.success)
        #expect(result.errors.count == 1)
        #expect(result.errors[0].localizedDescription.contains("failed.txt"))
    }

    @Test func nestedFailuresRetainOnlyAffectedBranches() async throws {
        let retainedDirectory = root.appendingPathComponent("retained/deep")
        let prunedDirectory = root.appendingPathComponent("pruned/deep")
        try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prunedDirectory, withIntermediateDirectories: true)

        let failed = retainedDirectory.appendingPathComponent("failed.bin")
        let retainedSibling = retainedDirectory.appendingPathComponent("successful.bin")
        let prunedFile = prunedDirectory.appendingPathComponent("successful.bin")
        try Data(repeating: 0x11, count: 3).write(to: failed)
        try Data(repeating: 0x22, count: 5).write(to: retainedSibling)
        try Data(repeating: 0x33, count: 7).write(to: prunedFile)

        let result = try await shredDirectory(failing: [failed.lastPathComponent])

        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(!FileManager.default.fileExists(atPath: retainedSibling.path))
        #expect(FileManager.default.fileExists(atPath: retainedDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: prunedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(result.filesShredded == 2)
        #expect(result.bytesShredded == 12)
        #expect(result.errors.count == 1)
        #expect(!result.success)
    }

    @Test func mixedFailuresPreserveRegularSymlinkAndSpecialEntries() async throws {
        let outsideTarget = temp.appendingPathComponent("outside-target.txt")
        try Data("outside".utf8).write(to: outsideTarget)

        let successful = root.appendingPathComponent("successful.txt")
        let failed = root.appendingPathComponent("failed.txt")
        let symlink = root.appendingPathComponent("outside-link")
        let fifo = root.appendingPathComponent("named-pipe")
        try Data("success".utf8).write(to: successful)
        try Data("failure".utf8).write(to: failed)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideTarget)
        try fifo.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            guard mkfifo(path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        var attemptedNames: Set<String> = []
        let result = try await SecureDelete.shredDirectory(
            at: root,
            level: .quick,
            progress: nil,
            fileShredder: { url, _ in
                attemptedNames.insert(url.lastPathComponent)
                if url.lastPathComponent == failed.lastPathComponent {
                    throw InjectedOverwriteFailure(url: url)
                }
                try FileManager.default.removeItem(at: url)
            }
        )

        #expect(attemptedNames == ["successful.txt", "failed.txt"])
        #expect(!FileManager.default.fileExists(atPath: successful.path))
        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)) != nil)
        #expect(FileManager.default.fileExists(atPath: fifo.path))
        #expect(try Data(contentsOf: outsideTarget) == Data("outside".utf8))
        #expect(result.filesShredded == 1)
        #expect(result.bytesShredded == Int64(Data("success".utf8).count))
        #expect(result.errors.count == 3)
        #expect(!result.success)
    }

    @Test func unexpectedLateArrivalIsRetainedAndReported() async throws {
        let initial = root.appendingPathComponent("initial.txt")
        let lateArrival = root.appendingPathComponent("late-arrival.txt")
        try Data("initial".utf8).write(to: initial)

        let result = try await SecureDelete.shredDirectory(
            at: root,
            level: .quick,
            progress: nil,
            fileShredder: { url, _ in
                try FileManager.default.removeItem(at: url)
                try Data("arrived during shredding".utf8).write(to: lateArrival)
            }
        )

        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: lateArrival.path))
        #expect(result.filesShredded == 1)
        #expect(!result.success)
        #expect(result.errors.contains { $0.localizedDescription.contains("not empty") })
    }

    @Test func allSuccessfulFilesAreRemovedAndEmptyDirectoriesPruned() async throws {
        let nested = root.appendingPathComponent("one/two")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt")
        let second = nested.appendingPathComponent("second.txt")
        try Data(repeating: 0x44, count: 4).write(to: first)
        try Data(repeating: 0x55, count: 6).write(to: second)

        let result = try await shredDirectory(failing: [])

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(result.filesShredded == 2)
        #expect(result.bytesShredded == 10)
        #expect(result.success)
        #expect(result.errors.isEmpty)
    }

    @Test func productionShredderRemovesFilesAndPrunesDirectoryTree() async throws {
        let nested = root.appendingPathComponent("one/two")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x66, count: 4).write(to: root.appendingPathComponent("first.txt"))
        try Data(repeating: 0x77, count: 6).write(to: nested.appendingPathComponent("second.txt"))

        let result = try await SecureDelete.shredDirectory(at: root, level: .quick)

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(result.filesShredded == 2)
        #expect(result.bytesShredded == 10)
        #expect(result.success)
        #expect(result.errors.isEmpty)
    }

    @Test func directorySymlinkIsRefusedWithoutTouchingTarget() async throws {
        let target = temp.appendingPathComponent("target-directory")
        let targetFile = target.appendingPathComponent("keep.txt")
        let link = temp.appendingPathComponent("selected-link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: targetFile)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        await #expect(throws: ShredError.self) {
            try await SecureDelete.shredDirectory(at: link, level: .quick)
        }

        #expect(try Data(contentsOf: targetFile) == Data("keep".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    private func shredDirectory(failing names: Set<String>) async throws -> ShredResult {
        try await SecureDelete.shredDirectory(
            at: root,
            level: .quick,
            progress: nil,
            fileShredder: { url, _ in
                if names.contains(url.lastPathComponent) {
                    try Data("partially overwritten".utf8).write(to: url)
                    throw InjectedOverwriteFailure(url: url)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
    }
}
