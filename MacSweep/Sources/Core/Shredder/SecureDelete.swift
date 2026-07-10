import Foundation
import CryptoKit
import Darwin

/// Secure file deletion with multiple overwrite passes.
///
/// IMPORTANT — overwriting is best-effort on modern Macs. APFS is
/// copy-on-write and SSDs do wear-levelling, so a write to "the same" logical
/// offset does not necessarily land on the physical blocks that held the
/// original data. Overwrite-based shredding therefore *cannot guarantee*
/// erasure on Apple Silicon / SSD / APFS hardware. The real guarantee is
/// FileVault: with full-disk encryption on, deleted data is unreadable
/// regardless of which physical blocks survive. UI copy must not overstate this.
// A namespace of static shredding helpers. (Previously an `actor`, but static
// methods on an actor are NOT actor-isolated, so the keyword guaranteed no
// serialization — `enum` states the "uninstantiable namespace" intent honestly.)
enum SecureDelete {

    enum ShredLevel: String, CaseIterable, Identifiable {
        case quick = "Quick"        // 1 pass random
        case standard = "Standard"  // 3 passes (DoD short)
        case secure = "Secure"      // 7 passes (DoD 5220.22-M)
        case paranoid = "Paranoid"  // 35 passes (Gutmann)

        var id: String { rawValue }

        var passes: Int {
            switch self {
            case .quick: return 1
            case .standard: return 3
            case .secure: return 7
            case .paranoid: return 35
            }
        }

        var description: String {
            switch self {
            case .quick:
                return "1 pass of random data. Fast but may be recoverable with specialized tools."
            case .standard:
                return "3 passes (DoD short). Good balance of speed and security."
            case .secure:
                return "7 passes (DoD 5220.22-M pattern). On SSD/APFS, overwrites can't guarantee the original blocks are erased."
            case .paranoid:
                return "35 passes (Gutmann method). Very slow. Same SSD/APFS caveat — keep FileVault on for a real guarantee."
            }
        }
    }

    /// Securely delete a file
    static func shred(
        file url: URL,
        level: ShredLevel = .standard,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        // Refuse symlinks BEFORE any fileExists check (which follows links):
        // FileHandle(forWritingTo:) opens through the link and would overwrite
        // the target's bytes — destroying unrelated data the user never selected.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw ShredError.refusedSymlink(url)
        }

        // Verify file exists and is a regular file
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw ShredError.notAFile(url)
        }

        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? Int64, fileSize > 0 else {
            // Empty file, just delete
            try FileManager.default.removeItem(at: url)
            Log.deletion(path: url, module: "shredder", disposition: .shred)
            return
        }

        // Open file for writing. No `defer`-close: the handle is closed explicitly
        // below, before the rename loop, and a deferred second close would just
        // double-close (benign EBADF) the already-closed handle. On an error path
        // the local handle is released and its fd closed at scope exit anyway.
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw ShredError.cannotOpenFile(url)
        }

        let totalPasses = level.passes
        let bufferSize = 65536  // 64KB buffer

        for pass in 0..<totalPasses {
            try handle.seek(toOffset: 0)

            var bytesWritten: Int64 = 0

            while bytesWritten < fileSize {
                let remaining = fileSize - bytesWritten
                let writeSize = min(Int(remaining), bufferSize)

                // Generate overwrite data based on pass pattern
                let data = generateOverwriteData(pass: pass, totalPasses: totalPasses, size: writeSize)

                try handle.write(contentsOf: data)
                bytesWritten += Int64(writeSize)

                // Report progress
                let overallProgress = (Double(pass) + Double(bytesWritten) / Double(fileSize)) / Double(totalPasses)
                progress?(overallProgress)
            }

            // Flush to disk
            try handle.synchronize()
        }

        // Close file
        try handle.close()

        // Rename file multiple times before deletion to obscure original name
        var currentURL = url
        for _ in 0..<3 {
            let randomName = UUID().uuidString
            let newURL = url.deletingLastPathComponent().appending(path: randomName)
            try FileManager.default.moveItem(at: currentURL, to: newURL)
            currentURL = newURL
        }

        // Finally delete
        try FileManager.default.removeItem(at: currentURL)
        // Log the ORIGINAL selected path (not the randomized temp name) so the
        // audit line matches what the user chose to destroy.
        Log.deletion(path: url, module: "shredder", disposition: .shred)

        progress?(1.0)
    }

    /// Securely delete a directory and all contents
    static func shredDirectory(
        at url: URL,
        level: ShredLevel = .standard,
        progress: ((String, Double) -> Void)? = nil
    ) async throws -> ShredResult {
        try await shredDirectory(
            at: url,
            level: level,
            progress: progress,
            fileShredder: { fileURL, fileLevel in
                try await shred(file: fileURL, level: fileLevel)
            }
        )
    }

    /// Internal injection seam used to deterministically exercise partial failures.
    static func shredDirectory(
        at url: URL,
        level: ShredLevel,
        progress: ((String, Double) -> Void)?,
        fileShredder: (URL, ShredLevel) async throws -> Void
    ) async throws -> ShredResult {
        var filesShredded = 0
        var bytesShredded: Int64 = 0
        var errors: [ShredError] = []
        var retainedPaths: [URL] = []

        // Fail closed on the selected root. In particular, never enumerate a
        // directory symlink and then unlink the link during container cleanup.
        let rootValues: URLResourceValues
        do {
            rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw ShredError.cannotInspectItem(url, error.localizedDescription)
        }
        if rootValues.isSymbolicLink == true {
            throw ShredError.refusedSymlink(url)
        }
        guard rootValues.isDirectory == true else {
            throw ShredError.notADirectory(url)
        }

        // Enumerate all files. Hidden files are INCLUDED (no .skipsHiddenFiles):
        // skipping them would leave dotfiles unprocessed. Each non-regular entry
        // is retained and reported rather than being swept up by recursive
        // directory removal.
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [],
            errorHandler: { itemURL, error in
                errors.append(.cannotInspectItem(itemURL, error.localizedDescription))
                retainedPaths.append(itemURL)
                return true
            }
        ) else {
            throw ShredError.cannotEnumerateDirectory(url)
        }

        var files: [(URL, Int64)] = []
        var directories: [URL] = []

        while let fileURL = enumerator.nextObject() as? URL {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            } catch {
                enumerator.skipDescendants()
                errors.append(.cannotInspectItem(fileURL, error.localizedDescription))
                retainedPaths.append(fileURL)
                continue
            }

            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                errors.append(.refusedSymlink(fileURL))
                retainedPaths.append(fileURL)
            } else if values.isDirectory == true {
                directories.append(fileURL)
            } else if values.isRegularFile == true {
                files.append((fileURL, Int64(values.fileSize ?? 0)))
            } else {
                enumerator.skipDescendants()
                errors.append(.unsupportedFileType(fileURL))
                retainedPaths.append(fileURL)
            }
        }

        let totalFiles = files.count

        // Shred each file
        for (index, (fileURL, fileSize)) in files.enumerated() {
            do {
                progress?(fileURL.lastPathComponent, Double(index) / Double(totalFiles))
                try await fileShredder(fileURL, level)
                filesShredded += 1
                bytesShredded += fileSize
            } catch let error as ShredError {
                errors.append(error)
                retainedPaths.append(fileURL)
            } catch {
                errors.append(.failedToShred(fileURL, error.localizedDescription))
                retainedPaths.append(fileURL)
            }
        }

        // `FileManager.removeItem` recursively unlinks a directory. Even after an
        // emptiness check, a file appearing in the race window could therefore be
        // deleted without an overwrite. POSIX rmdir is the required primitive:
        // it removes only an empty directory and never follows a final symlink.
        let directoriesToPrune = directories.sorted {
            $0.standardizedFileURL.pathComponents.count > $1.standardizedFileURL.pathComponents.count
        } + [url]

        for directory in directoriesToPrune {
            let result = directory.withUnsafeFileSystemRepresentation { path in
                guard let path else {
                    errno = EINVAL
                    return Int32(-1)
                }
                return Darwin.rmdir(path)
            }

            if result == 0 {
                Log.deletion(path: directory, module: "shredder", disposition: .shred)
                continue
            }

            let errorCode = errno
            let hasRetainedDescendant = retainedPaths.contains {
                isSameOrDescendant($0, of: directory)
            }
            if (errorCode == ENOTEMPTY || errorCode == EEXIST), hasRetainedDescendant {
                continue
            }

            let removalError = NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [NSFilePathErrorKey: directory.path]
            )
            errors.append(.cannotRemoveDirectory(directory, removalError.localizedDescription))
            retainedPaths.append(directory)
            Log.deletion(path: directory, module: "shredder", disposition: .shred, error: removalError)
        }

        progress?(errors.isEmpty ? "Complete" : "Completed with errors", 1.0)

        return ShredResult(
            filesShredded: filesShredded,
            bytesShredded: bytesShredded,
            errors: errors
        )
    }

    private static func isSameOrDescendant(_ item: URL, of directory: URL) -> Bool {
        let itemComponents = item.standardizedFileURL.pathComponents
        let directoryComponents = directory.standardizedFileURL.pathComponents
        guard itemComponents.count >= directoryComponents.count else { return false }
        return itemComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents)
    }

    /// Generate overwrite data for a specific pass
    private static func generateOverwriteData(pass: Int, totalPasses: Int, size: Int) -> Data {
        switch totalPasses {
        case 1:
            // Quick: random data
            return randomData(size: size)

        case 3:
            // DoD short: 0x00, 0xFF, random
            switch pass {
            case 0: return Data(repeating: 0x00, count: size)
            case 1: return Data(repeating: 0xFF, count: size)
            default: return randomData(size: size)
            }

        case 7:
            // DoD 5220.22-M
            switch pass {
            case 0: return Data(repeating: 0x00, count: size)
            case 1: return Data(repeating: 0xFF, count: size)
            case 2: return randomData(size: size)
            case 3: return Data(repeating: 0x00, count: size)
            case 4: return Data(repeating: 0xFF, count: size)
            case 5: return Data(repeating: 0x00, count: size)
            default: return randomData(size: size)
            }

        default:
            // Gutmann or other: use specific patterns for some passes, random for others
            if pass < gutmannPatterns.count {
                return patternData(pattern: gutmannPatterns[pass], size: size)
            }
            return randomData(size: size)
        }
    }

    private static func randomData(size: Int) -> Data {
        // A zero-length buffer has a nil baseAddress; force-unwrapping it crashed.
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, size, base)
        }
        // A secure wipe must never silently fall back to predictable bytes. If
        // the system CSPRNG is unavailable, fill from the system RNG rather than
        // leaving the all-zero buffer SecRandomCopyBytes may have left behind.
        if status != errSecSuccess {
            for index in 0..<size {
                data[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        return data
    }

    private static func patternData(pattern: [UInt8], size: Int) -> Data {
        var data = Data(capacity: size)
        var index = 0
        while data.count < size {
            data.append(pattern[index % pattern.count])
            index += 1
        }
        return data
    }

    // Gutmann patterns (simplified subset)
    private static let gutmannPatterns: [[UInt8]] = [
        [0x55], [0xAA], [0x92, 0x49, 0x24], [0x49, 0x24, 0x92],
        [0x24, 0x92, 0x49], [0x00], [0x11], [0x22],
        [0x33], [0x44], [0x55], [0x66], [0x77],
        [0x88], [0x99], [0xAA], [0xBB], [0xCC],
        [0xDD], [0xEE], [0xFF], [0x92, 0x49, 0x24],
        [0x49, 0x24, 0x92], [0x24, 0x92, 0x49], [0x6D, 0xB6, 0xDB],
        [0xB6, 0xDB, 0x6D], [0xDB, 0x6D, 0xB6],
    ]
}

// MARK: - Result Types

struct ShredResult {
    let filesShredded: Int
    let bytesShredded: Int64
    let errors: [ShredError]

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: bytesShredded, countStyle: .file)
    }

    var success: Bool {
        errors.isEmpty
    }
}

enum ShredError: LocalizedError {
    case notAFile(URL)
    case notADirectory(URL)
    case cannotOpenFile(URL)
    case cannotEnumerateDirectory(URL)
    case cannotInspectItem(URL, String)
    case unsupportedFileType(URL)
    case failedToShred(URL, String)
    case cannotRemoveDirectory(URL, String)
    case writeFailed(URL)
    case refusedSymlink(URL)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notAFile(let url):
            return "Not a file: \(url.lastPathComponent)"
        case .notADirectory(let url):
            return "Not a directory: \(url.path)"
        case .cannotOpenFile(let url):
            return "Cannot open file: \(url.lastPathComponent)"
        case .cannotEnumerateDirectory(let url):
            return "Cannot enumerate directory: \(url.lastPathComponent)"
        case .cannotInspectItem(let url, let reason):
            return "Cannot inspect item; left in place: \(url.path) (\(reason))"
        case .unsupportedFileType(let url):
            return "Unsupported file type; left in place: \(url.path)"
        case .failedToShred(let url, let reason):
            return "Shredding did not complete for \(url.path): \(reason)"
        case .cannotRemoveDirectory(let url, let reason):
            return "Cannot remove directory \(url.path): \(reason)"
        case .writeFailed(let url):
            return "Write failed: \(url.lastPathComponent)"
        case .refusedSymlink(let url):
            return "Refused symlink; left in place to avoid following its target: \(url.path)"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Free Space Wipe

extension SecureDelete {
    /// Wipe free space on a volume (writes and deletes temporary files)
    static func wipeFreeSpace(
        volume: URL = URL(fileURLWithPath: "/"),
        level: ShredLevel = .quick,
        progress: ((Double) -> Void)? = nil
    ) async throws {
        // Get available space
        let values = try volume.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacity else {
            throw ShredError.unknown("Cannot determine available space")
        }

        // Reserve some space (1GB minimum)
        let toWrite = max(0, Int64(available) - 1_073_741_824)
        guard toWrite > 0 else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "macsweep_wipe_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunkSize: Int64 = 100_000_000  // 100MB chunks
        var written: Int64 = 0
        var fileIndex = 0

        while written < toWrite {
            let remaining = toWrite - written
            let writeSize = min(remaining, chunkSize)

            let tempFile = tempDir.appending(path: "wipe_\(fileIndex)")

            // Create file with random data. We reserved 1 GB of headroom, so a
            // failure here is a real error (I/O, permissions), NOT normal
            // disk-full — surface it instead of silently reporting progress 1.0.
            let created = FileManager.default.createFile(atPath: tempFile.path, contents: nil)
            guard created else {
                throw ShredError.writeFailed(tempFile)
            }

            guard let writeHandle = try? FileHandle(forWritingTo: tempFile) else {
                throw ShredError.cannotOpenFile(tempFile)
            }

            // Write random data. A failure here (e.g. the volume filling
            // unexpectedly) must surface — silently swallowing it and then
            // reporting progress 1.0 would falsely claim the wipe succeeded.
            var writeError: Error?
            var chunkWritten: Int64 = 0
            while chunkWritten < writeSize {
                let batchSize = min(65536, Int(writeSize - chunkWritten))
                let data = randomData(size: batchSize)
                do {
                    try writeHandle.write(contentsOf: data)
                } catch {
                    writeError = error
                    break
                }
                chunkWritten += Int64(batchSize)
            }

            try? writeHandle.synchronize()
            try? writeHandle.close()

            if writeError != nil {
                throw ShredError.writeFailed(tempFile)
            }

            written += writeSize
            fileIndex += 1

            progress?(Double(written) / Double(toWrite))
        }

        // Delete all temp files
        try? FileManager.default.removeItem(at: tempDir)

        progress?(1.0)
    }
}
