import Foundation
import CryptoKit

/// Secure file deletion with multiple overwrite passes
actor SecureDelete {

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
                return "7 passes (DoD 5220.22-M). Meets government security standards."
            case .paranoid:
                return "35 passes (Gutmann method). Maximum security, very slow."
            }
        }
    }

    /// Securely delete a file
    static func shred(
        file url: URL,
        level: ShredLevel = .standard,
        progress: ((Double) -> Void)? = nil
    ) async throws {
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
            return
        }

        // Open file for writing
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ShredError.cannotOpenFile(url)
        }

        defer {
            try? handle.close()
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

        progress?(1.0)
    }

    /// Securely delete a directory and all contents
    static func shredDirectory(
        at url: URL,
        level: ShredLevel = .standard,
        progress: ((String, Double) -> Void)? = nil
    ) async throws -> ShredResult {
        var filesShredded = 0
        var bytesShredded: Int64 = 0
        var errors: [ShredError] = []

        // Enumerate all files
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ShredError.cannotEnumerateDirectory(url)
        }

        var files: [(URL, Int64)] = []

        while let fileURL = enumerator.nextObject() as? URL {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == false {
                let size = Int64(values?.fileSize ?? 0)
                files.append((fileURL, size))
                bytesShredded += size
            }
        }

        let totalFiles = files.count

        // Shred each file
        for (index, (fileURL, _)) in files.enumerated() {
            do {
                progress?(fileURL.lastPathComponent, Double(index) / Double(totalFiles))
                try await shred(file: fileURL, level: level)
                filesShredded += 1
            } catch let error as ShredError {
                errors.append(error)
            } catch {
                errors.append(.unknown(error.localizedDescription))
            }
        }

        // Remove empty directories
        try? FileManager.default.removeItem(at: url)

        progress?("Complete", 1.0)

        return ShredResult(
            filesShredded: filesShredded,
            bytesShredded: bytesShredded,
            errors: errors
        )
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
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, size, ptr.baseAddress!)
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
    case cannotOpenFile(URL)
    case cannotEnumerateDirectory(URL)
    case writeFailed(URL)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notAFile(let url):
            return "Not a file: \(url.lastPathComponent)"
        case .cannotOpenFile(let url):
            return "Cannot open file: \(url.lastPathComponent)"
        case .cannotEnumerateDirectory(let url):
            return "Cannot enumerate directory: \(url.lastPathComponent)"
        case .writeFailed(let url):
            return "Write failed: \(url.lastPathComponent)"
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

            // Create file with random data
            let created = FileManager.default.createFile(atPath: tempFile.path, contents: nil)
            guard created else {
                break
            }

            guard let writeHandle = try? FileHandle(forWritingTo: tempFile) else {
                break
            }

            // Write random data
            var chunkWritten: Int64 = 0
            while chunkWritten < writeSize {
                let batchSize = min(65536, Int(writeSize - chunkWritten))
                let data = randomData(size: batchSize)
                try? writeHandle.write(contentsOf: data)
                chunkWritten += Int64(batchSize)
            }

            try? writeHandle.synchronize()
            try? writeHandle.close()

            written += writeSize
            fileIndex += 1

            progress?(Double(written) / Double(toWrite))
        }

        // Delete all temp files
        try? FileManager.default.removeItem(at: tempDir)

        progress?(1.0)
    }
}
