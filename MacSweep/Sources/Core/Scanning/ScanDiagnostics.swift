import Foundation

struct PartialModuleScanError: Error, LocalizedError {
    let items: [CleanupItem]
    let issues: [String]
    var errorDescription: String? {
        "Incomplete scan: " + issues.prefix(5).joined(separator: "; ")
    }
}

enum ScanDiagnostics {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func record(_ error: Error, at path: URL) {
            guard !(error is CancellationError) else { return }
            lock.lock()
            defer { lock.unlock() }
            let message = "\(path.path): \(error.localizedDescription)"
            if !messages.contains(message) { messages.append(message) }
        }
        var issues: [String] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    @TaskLocal static var current: Collector?

    static func collect(_ body: () async throws -> [CleanupItem]) async throws -> [CleanupItem] {
        if current != nil { return try await body() }
        let collector = Collector()
        return try await $current.withValue(collector) {
            let items = try await body()
            try Task.checkCancellation()
            if !collector.issues.isEmpty {
                throw PartialModuleScanError(items: items, issues: collector.issues)
            }
            return items
        }
    }
}

enum ScanFileSystem {
    static func contentsOfDirectory(atPath path: String) throws -> [String] {
        try contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil).map(\.lastPathComponent)
    }

    static func exists(atPath path: String) -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return true
        } catch {
            let error = error as NSError
            if !isAbsentOptionalPath(error) {
                ScanDiagnostics.current?.record(error, at: URL(fileURLWithPath: path))
            }
            return false
        }
    }

    private static func isAbsentOptionalPath(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain,
           [POSIXErrorCode.ENOENT.rawValue, POSIXErrorCode.ENOTDIR.rawValue].contains(Int32(error.code)) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isAbsentOptionalPath(underlying)
        }
        return false
    }

    static func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
                ScanDiagnostics.current?.record(error, at: url)
            }
            throw error
        }
    }

    static func enumerator(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions = []
    ) -> FileManager.DirectoryEnumerator? {
        guard exists(atPath: url.path) else { return nil }
        guard (try? contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) != nil else { return nil }
        let collector = ScanDiagnostics.current
        return FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: options) { path, error in
            collector?.record(error, at: path)
            return true
        }
    }
}

extension URL {
    func scanResourceValues(forKeys keys: Set<URLResourceKey>) throws -> URLResourceValues {
        do { return try resourceValues(forKeys: keys) }
        catch {
            ScanDiagnostics.current?.record(error, at: self)
            throw error
        }
    }
}
