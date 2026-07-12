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

    /// Securely delete a regular file through a pinned descriptor.
    @discardableResult
    static func shred(
        file url: URL,
        level: ShredLevel = .standard,
        progress: ((Double) -> Void)? = nil
    ) async throws -> Int64 {
        try DescriptorSecureDelete.shredFile(at: url, level: level, progress: progress)
    }

    /// Securely delete a directory and all contents
    static func shredDirectory(
        at url: URL,
        level: ShredLevel = .standard,
        progress: ((String, Double) -> Void)? = nil
    ) async throws -> ShredResult {
        try await DescriptorSecureDelete.shredDirectory(
            at: url,
            level: level,
            progress: progress,
            injectedFileShredder: nil
        )
    }

    /// Internal injection seam used by deterministic partial-failure tests.
    static func shredDirectory(
        at url: URL,
        level: ShredLevel,
        progress: ((String, Double) -> Void)?,
        fileShredder: @escaping DescriptorSecureDelete.InjectedFileShredder
    ) async throws -> ShredResult {
        try await DescriptorSecureDelete.shredDirectory(
            at: url,
            level: level,
            progress: progress,
            injectedFileShredder: fileShredder
        )
    }

    /// Generate overwrite data for a specific pass
    static func generateOverwriteData(pass: Int, totalPasses: Int, size: Int) -> Data {
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
    case cannotOpenDirectory(URL, String)
    case cannotEnumerateDirectory(URL)
    case cannotInspectItem(URL, String)
    case unsupportedFileType(URL)
    case hardLinkedFile(URL)
    case identityChanged(URL, String)
    case failedToShred(URL, String)
    case verificationFailed(URL)
    case fileChangedDuringShred(URL)
    case cannotRemoveItem(URL, String)
    case cannotRemoveDirectory(URL, String)
    case unexpectedRetainedItem(URL)
    case byteCountOverflow(URL)
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
            return "Cannot open file; left in place: \(url.path)"
        case .cannotOpenDirectory(let url, let reason):
            return "Cannot open directory; left in place: \(url.path) (\(reason))"
        case .cannotEnumerateDirectory(let url):
            return "Cannot enumerate directory: \(url.lastPathComponent)"
        case .cannotInspectItem(let url, let reason):
            return "Cannot inspect item; left in place: \(url.path) (\(reason))"
        case .unsupportedFileType(let url):
            return "Unsupported file type; left in place: \(url.path)"
        case .hardLinkedFile(let url):
            return "Hard-linked file was not shredded or unlinked: \(url.path)"
        case .identityChanged(let url, let reason):
            return "Selected item changed identity and was retained: \(url.path) (\(reason))"
        case .failedToShred(let url, let reason):
            return "Shredding did not complete for \(url.path): \(reason)"
        case .verificationFailed(let url):
            return "Overwrite verification failed; file was retained: \(url.path)"
        case .fileChangedDuringShred(let url):
            return "File size or identity changed during overwrite; file was retained: \(url.path)"
        case .cannotRemoveItem(let url, let reason):
            return "Cannot unlink shredded file; retained at \(url.path) (\(reason))"
        case .cannotRemoveDirectory(let url, let reason):
            return "Cannot remove directory \(url.path): \(reason)"
        case .unexpectedRetainedItem(let url):
            return "Item appeared during shredding and was not processed; left in place: \(url.path)"
        case .byteCountOverflow(let url):
            return "Shredded byte count overflow near \(url.path); reported total was saturated"
        case .writeFailed(let url):
            return "Write failed; file was retained: \(url.path)"
        case .refusedSymlink(let url):
            return "Refused symlink; left in place to avoid following its target: \(url.path)"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Free Space Wipe

extension SecureDelete {
    /// Creates a writable scratch directory on the selected volume.
    /// Kept separate from the write loop so the volume-placement safety
    /// contract can be verified without consuming free space in tests.
    static func makeFreeSpaceWipeDirectory(on volume: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: volume,
            create: true
        )
    }

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

        // `.itemReplacementDirectory` is writable and guaranteed to live on
        // the same volume as `volume`. Using the process-wide temporary
        // directory here could fill the boot disk while claiming to wipe an
        // external volume.
        let tempDir = try makeFreeSpaceWipeDirectory(on: volume)

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
