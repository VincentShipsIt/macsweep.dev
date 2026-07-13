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

    @Test func freeSpaceWipeScratchDirectoryLivesOnRequestedVolume() throws {
        let scratch = try SecureDelete.makeFreeSpaceWipeDirectory(on: root)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let requestedVolume = try #require(
            root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? AnyHashable
        )
        let scratchValues = try scratch.resourceValues(forKeys: [.isDirectoryKey, .volumeIdentifierKey])
        let scratchVolume = try #require(scratchValues.volumeIdentifier as? AnyHashable)

        #expect(scratchValues.isDirectory == true)
        #expect(scratchVolume == requestedVolume)
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
                let size = try self.liveSize(of: url)
                try FileManager.default.removeItem(at: url)
                return size
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
                let size = try self.liveSize(of: url)
                try FileManager.default.removeItem(at: url)
                try Data("arrived during shredding".utf8).write(to: lateArrival)
                return size
            }
        )

        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: lateArrival.path))
        #expect(result.filesShredded == 1)
        #expect(!result.success)
        #expect(result.errors.contains { $0.localizedDescription.contains("late-arrival.txt") })
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

    @Test func swappedAncestorCannotRedirectPruningOutsideSelection() async throws {
        let ancestor = root.appendingPathComponent("ancestor")
        let selectedLeaf = ancestor.appendingPathComponent("leaf")
        let selected = selectedLeaf.appendingPathComponent("selected.txt")
        let displacedAncestor = temp.appendingPathComponent("displaced-ancestor")
        let outside = temp.appendingPathComponent("outside")
        let outsideLeaf = outside.appendingPathComponent("leaf")
        try FileManager.default.createDirectory(at: selectedLeaf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideLeaf, withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: selected)

        let result = try await SecureDelete.shredDirectory(
            at: root,
            level: .quick,
            progress: nil,
            fileShredder: { url, _ in
                let size = try self.liveSize(of: url)
                try FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: ancestor, to: displacedAncestor)
                try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: outside)
                return size
            }
        )

        #expect(FileManager.default.fileExists(atPath: outsideLeaf.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil)
        #expect(result.filesShredded == 1)
        #expect(!result.success)
    }

    @Test func productionByteAccountingUsesTheLiveSizeActuallyShredded() async throws {
        let first = root.appendingPathComponent("a-first.bin")
        let second = root.appendingPathComponent("z-second.bin")
        try Data(repeating: 0x11, count: 3).write(to: first)
        try Data(repeating: 0x22, count: 2).write(to: second)

        var didMutate = false
        var expectedBytes: Int64 = 0
        var mutationError: Error?
        let result = try await SecureDelete.shredDirectory(
            at: root,
            level: .quick
        ) { name, _ in
            guard !didMutate else { return }
            didMutate = true
            let current = name == first.lastPathComponent ? first : second
            let sibling = current == first ? second : first
            do {
                expectedBytes = try self.liveSize(of: current)
                try Data(repeating: 0x33, count: 11).write(to: sibling)
                expectedBytes += 11
            } catch {
                mutationError = error
            }
        }

        #expect(mutationError == nil)
        #expect(result.success)
        #expect(result.filesShredded == 2)
        #expect(result.bytesShredded == expectedBytes)
        #expect(expectedBytes > 5)
    }

    @Test func directShredRejectsHardLinksWithoutOverwritingTheirPeer() async throws {
        let peer = root.appendingPathComponent("peer.bin")
        let selected = root.appendingPathComponent("selected-hard-link.bin")
        let original = Data("shared inode must remain".utf8)
        try original.write(to: peer)
        try FileManager.default.linkItem(at: peer, to: selected)

        await #expect(throws: ShredError.self) {
            try await SecureDelete.shred(file: selected, level: .quick)
        }

        #expect(try Data(contentsOf: peer) == original)
        #expect(try Data(contentsOf: selected) == original)
    }

    @Test func directShredRejectsFIFOAndSpecialNodesWithoutUnlinkingThem() async throws {
        let fifo = root.appendingPathComponent("named-pipe")
        try fifo.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            guard mkfifo(path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        await #expect(throws: ShredError.self) {
            try await SecureDelete.shred(file: fifo, level: .quick)
        }
        #expect(FileManager.default.fileExists(atPath: fifo.path))

        let characterDevice = URL(fileURLWithPath: "/dev/null")
        await #expect(throws: ShredError.self) {
            try await SecureDelete.shred(file: characterDevice, level: .quick)
        }
        #expect(FileManager.default.fileExists(atPath: characterDevice.path))
    }

    @Test func swappedIntermediateDirectoryCannotRedirectDirectUnlink() async throws {
        let ancestor = root.appendingPathComponent("ancestor")
        let selected = ancestor.appendingPathComponent("selected.bin")
        let displacedAncestor = temp.appendingPathComponent("displaced-direct")
        let outside = temp.appendingPathComponent("outside-direct")
        let outsideFile = outside.appendingPathComponent(selected.lastPathComponent)
        try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 128).write(to: selected)
        try Data("outside survives".utf8).write(to: outsideFile)

        var swapped = false
        var injectionError: Error?
        let bytes = try await SecureDelete.shred(file: selected, level: .quick) { _ in
            guard !swapped else { return }
            swapped = true
            do {
                try FileManager.default.moveItem(at: ancestor, to: displacedAncestor)
                try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: outside)
            } catch {
                injectionError = error
            }
        }

        #expect(injectionError == nil)
        #expect(bytes == 128)
        #expect(try Data(contentsOf: outsideFile) == Data("outside survives".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: displacedAncestor.appendingPathComponent(selected.lastPathComponent).path
        ))
    }

    @Test func replacementAtFinalNameIsRetainedAfterOverwrite() async throws {
        let selected = root.appendingPathComponent("selected.bin")
        let openedOriginal = root.appendingPathComponent("opened-original.bin")
        let replacement = Data("replacement survives".utf8)
        try Data(repeating: 0x55, count: 128).write(to: selected)

        var replaced = false
        var injectionError: Error?
        var caughtError: ShredError?
        do {
            _ = try await SecureDelete.shred(file: selected, level: .quick) { _ in
                guard !replaced else { return }
                replaced = true
                do {
                    try FileManager.default.moveItem(at: selected, to: openedOriginal)
                    try replacement.write(to: selected)
                } catch {
                    injectionError = error
                }
            }
        } catch let error as ShredError {
            caughtError = error
        }

        #expect(injectionError == nil)
        #expect(caughtError != nil)
        #expect(try Data(contentsOf: selected) == replacement)
        #expect(FileManager.default.fileExists(atPath: openedOriginal.path))
    }

    @Test func lateArrivalBesideKnownFailureIsReportedSeparately() async throws {
        let failed = root.appendingPathComponent("failed.bin")
        let late = root.appendingPathComponent("late.bin")
        try Data("retain".utf8).write(to: failed)

        let result = try await SecureDelete.shredDirectory(
            at: root,
            level: .quick,
            progress: nil,
            fileShredder: { url, _ in
                try Data("late".utf8).write(to: late)
                throw InjectedOverwriteFailure(url: url)
            }
        )

        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(FileManager.default.fileExists(atPath: late.path))
        #expect(result.errors.contains { $0.localizedDescription.contains("failed.bin") })
        #expect(result.errors.contains { $0.localizedDescription.contains("late.bin") })
        #expect(result.errors.count == 2)
    }

    @Test func byteAccountingOverflowSaturatesAndReportsFailure() async throws {
        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.bin")
        try Data([0x01]).write(to: first)
        try Data([0x02]).write(to: second)

        let result = try await SecureDelete.shredDirectory(
            at: root,
            level: .quick,
            progress: nil,
            fileShredder: { url, _ in
                let credited = url.lastPathComponent == first.lastPathComponent ? Int64.max : 1
                try FileManager.default.removeItem(at: url)
                return credited
            }
        )

        #expect(result.filesShredded == 2)
        #expect(result.bytesShredded == Int64.max)
        #expect(!result.success)
        #expect(result.errors.contains { $0.localizedDescription.localizedCaseInsensitiveContains("overflow") })
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
                let size = try self.liveSize(of: url)
                try FileManager.default.removeItem(at: url)
                return size
            }
        )
    }

    private func liveSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}
