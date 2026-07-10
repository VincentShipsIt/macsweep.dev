import CryptoKit
import Darwin
import Foundation

/// Descriptor-relative primitives for the shredder's destructive operations.
///
/// Every selected parent directory and target vnode is pinned before overwrite.
/// Namespace changes are performed relative to those pinned descriptors, and the
/// randomly renamed entry is re-identified before it is unlinked.
enum DescriptorSecureDelete {
    typealias InjectedFileShredder = (URL, SecureDelete.ShredLevel) async throws -> Int64

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
        }
    }

    private struct DirectoryContext {
        let level: SecureDelete.ShredLevel
        let progress: ((String, Double) -> Void)?
        let injectedFileShredder: InjectedFileShredder?
        var filesShredded = 0
        var bytesShredded: Int64 = 0
        var errors: [ShredError] = []
        var reportedOverflow = false
    }

    static func shredFile(
        at displayURL: URL,
        level: SecureDelete.ShredLevel,
        progress: ((Double) -> Void)?
    ) throws -> Int64 {
        let resolvedURL = systemAliasNormalized(displayURL)
        let parentURL = resolvedURL.deletingLastPathComponent()
        let name = resolvedURL.lastPathComponent
        guard !name.isEmpty else {
            throw ShredError.notAFile(displayURL)
        }

        let parentFD = try openDirectory(path: parentURL.path, displayURL: displayURL)
        defer { close(parentFD) }

        return try shredPinnedFile(
            parentFD: parentFD,
            name: name,
            displayURL: displayURL,
            level: level,
            progress: progress
        )
    }

    static func shredDirectory(
        at displayURL: URL,
        level: SecureDelete.ShredLevel,
        progress: ((String, Double) -> Void)?,
        injectedFileShredder: InjectedFileShredder?
    ) async throws -> ShredResult {
        let resolvedURL = systemAliasNormalized(displayURL)
        let parentURL = resolvedURL.deletingLastPathComponent()
        let name = resolvedURL.lastPathComponent
        guard !name.isEmpty else {
            throw ShredError.notADirectory(displayURL)
        }

        let parentFD = try openDirectory(path: parentURL.path, displayURL: displayURL)
        defer { close(parentFD) }

        var entryStatus = stat()
        guard fstatat(parentFD, name, &entryStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw inspectionError(displayURL)
        }
        let kind = entryStatus.st_mode & S_IFMT
        if kind == S_IFLNK {
            throw ShredError.refusedSymlink(displayURL)
        }
        guard kind == S_IFDIR else {
            throw ShredError.notADirectory(displayURL)
        }

        let directoryFD = openat(
            parentFD,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
        )
        guard directoryFD >= 0 else {
            throw ShredError.cannotOpenDirectory(displayURL, posixDescription(errno))
        }
        defer { close(directoryFD) }

        var openedStatus = stat()
        guard fstat(directoryFD, &openedStatus) == 0 else {
            throw inspectionError(displayURL)
        }
        guard FileIdentity(openedStatus) == FileIdentity(entryStatus) else {
            throw ShredError.identityChanged(displayURL, "directory changed while it was being opened")
        }

        var context = DirectoryContext(
            level: level,
            progress: progress,
            injectedFileShredder: injectedFileShredder
        )
        _ = await processDirectory(
            parentFD: parentFD,
            name: name,
            directoryFD: directoryFD,
            identity: FileIdentity(openedStatus),
            displayURL: displayURL,
            context: &context
        )

        progress?(context.errors.isEmpty ? "Complete" : "Completed with errors", 1.0)
        return ShredResult(
            filesShredded: context.filesShredded,
            bytesShredded: context.bytesShredded,
            errors: context.errors
        )
    }

    private static func processDirectory(
        parentFD: Int32,
        name: String,
        directoryFD: Int32,
        identity: FileIdentity,
        displayURL: URL,
        context: inout DirectoryContext
    ) async -> Bool {
        let snapshot: [String]
        do {
            snapshot = try entryNames(in: directoryFD)
        } catch {
            context.errors.append(.cannotInspectItem(displayURL, error.localizedDescription))
            return false
        }

        var expectedRetainedNames = Set<String>()
        for childName in snapshot {
            let childURL = displayURL.appendingPathComponent(childName)
            var childStatus = stat()
            guard fstatat(directoryFD, childName, &childStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
                context.errors.append(.cannotInspectItem(childURL, posixDescription(errno)))
                expectedRetainedNames.insert(childName)
                continue
            }

            switch childStatus.st_mode & S_IFMT {
            case S_IFREG:
                context.progress?(childName, 0)
                do {
                    let shreddedBytes: Int64
                    if let injected = context.injectedFileShredder {
                        shreddedBytes = try await injected(childURL, context.level)
                        var remainingStatus = stat()
                        if fstatat(directoryFD, childName, &remainingStatus, AT_SYMLINK_NOFOLLOW) == 0 {
                            throw ShredError.failedToShred(
                                childURL,
                                "shredder reported success but the selected entry is still present"
                            )
                        }
                        if errno != ENOENT {
                            throw ShredError.cannotInspectItem(childURL, posixDescription(errno))
                        }
                    } else {
                        shreddedBytes = try shredPinnedFile(
                            parentFD: directoryFD,
                            name: childName,
                            displayURL: childURL,
                            level: context.level,
                            expectedIdentity: FileIdentity(childStatus),
                            progress: nil
                        )
                    }
                    context.filesShredded += 1
                    addBytes(shreddedBytes, for: childURL, context: &context)
                } catch let error as ShredError {
                    context.errors.append(error)
                    expectedRetainedNames.insert(childName)
                } catch {
                    context.errors.append(.failedToShred(childURL, error.localizedDescription))
                    expectedRetainedNames.insert(childName)
                }

            case S_IFDIR:
                let childFD = openat(
                    directoryFD,
                    childName,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
                )
                guard childFD >= 0 else {
                    context.errors.append(.cannotOpenDirectory(childURL, posixDescription(errno)))
                    expectedRetainedNames.insert(childName)
                    continue
                }

                var openedStatus = stat()
                let inspected = fstat(childFD, &openedStatus) == 0
                guard inspected, FileIdentity(openedStatus) == FileIdentity(childStatus) else {
                    let reason = inspected
                        ? "directory changed while it was being opened"
                        : posixDescription(errno)
                    context.errors.append(.identityChanged(childURL, reason))
                    expectedRetainedNames.insert(childName)
                    close(childFD)
                    continue
                }

                let removed = await processDirectory(
                    parentFD: directoryFD,
                    name: childName,
                    directoryFD: childFD,
                    identity: FileIdentity(openedStatus),
                    displayURL: childURL,
                    context: &context
                )
                close(childFD)
                if !removed {
                    expectedRetainedNames.insert(childName)
                }

            case S_IFLNK:
                context.errors.append(.refusedSymlink(childURL))
                expectedRetainedNames.insert(childName)

            default:
                context.errors.append(.unsupportedFileType(childURL))
                expectedRetainedNames.insert(childName)
            }
        }

        let currentNames: Set<String>
        do {
            currentNames = Set(try entryNames(in: directoryFD))
        } catch {
            context.errors.append(.cannotInspectItem(displayURL, error.localizedDescription))
            return false
        }

        for unexpectedName in currentNames.subtracting(expectedRetainedNames).sorted() {
            let unexpectedURL = displayURL.appendingPathComponent(unexpectedName)
            context.errors.append(.unexpectedRetainedItem(unexpectedURL))
            expectedRetainedNames.insert(unexpectedName)
        }

        guard currentNames.isEmpty else {
            return false
        }

        do {
            try removePinnedEntry(
                parentFD: parentFD,
                name: name,
                identity: identity,
                displayURL: displayURL,
                isDirectory: true
            )
            Log.deletion(path: displayURL, module: "shredder", disposition: .shred)
            return true
        } catch let error as ShredError {
            context.errors.append(error)
        } catch {
            context.errors.append(.cannotRemoveDirectory(displayURL, error.localizedDescription))
        }
        return false
    }

    private static func shredPinnedFile(
        parentFD: Int32,
        name: String,
        displayURL: URL,
        level: SecureDelete.ShredLevel,
        expectedIdentity: FileIdentity? = nil,
        progress: ((Double) -> Void)?
    ) throws -> Int64 {
        var inspectedStatus = stat()
        guard fstatat(parentFD, name, &inspectedStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw inspectionError(displayURL)
        }

        switch inspectedStatus.st_mode & S_IFMT {
        case S_IFLNK:
            throw ShredError.refusedSymlink(displayURL)
        case S_IFREG:
            break
        default:
            throw ShredError.unsupportedFileType(displayURL)
        }
        guard inspectedStatus.st_nlink == 1 else {
            throw ShredError.hardLinkedFile(displayURL)
        }
        let inspectedIdentity = FileIdentity(inspectedStatus)
        if let expectedIdentity, inspectedIdentity != expectedIdentity {
            throw ShredError.identityChanged(displayURL, "file changed after directory enumeration")
        }

        let descriptor = openat(
            parentFD,
            name,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | O_EXLOCK | O_UNIQUE | O_RESOLVE_BENEATH
        )
        guard descriptor >= 0 else {
            throw ShredError.cannotOpenFile(displayURL)
        }
        defer { close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0 else {
            throw inspectionError(displayURL)
        }
        guard openedStatus.st_mode & S_IFMT == S_IFREG else {
            throw ShredError.unsupportedFileType(displayURL)
        }
        guard openedStatus.st_nlink == 1 else {
            throw ShredError.hardLinkedFile(displayURL)
        }
        let identity = FileIdentity(openedStatus)
        guard identity == inspectedIdentity else {
            throw ShredError.identityChanged(displayURL, "file changed while it was being opened")
        }
        guard openedStatus.st_size >= 0 else {
            throw ShredError.cannotInspectItem(displayURL, "negative file size")
        }
        let acceptedSize = Int64(openedStatus.st_size)

        for pass in 0..<level.passes {
            var expectedHash = SHA256()
            var offset: Int64 = 0
            while offset < acceptedSize {
                let count = min(Int(acceptedSize - offset), 65_536)
                let data = SecureDelete.generateOverwriteData(
                    pass: pass,
                    totalPasses: level.passes,
                    size: count
                )
                try writeAll(data, to: descriptor, at: offset, displayURL: displayURL)
                expectedHash.update(data: data)
                offset += Int64(count)
                let value = (Double(pass) + Double(offset) / Double(max(acceptedSize, 1)))
                    / Double(level.passes)
                progress?(value)
            }

            guard fsync(descriptor) == 0 else {
                throw ShredError.writeFailed(displayURL)
            }

            var currentStatus = stat()
            guard fstat(descriptor, &currentStatus) == 0 else {
                throw inspectionError(displayURL)
            }
            guard FileIdentity(currentStatus) == identity, Int64(currentStatus.st_size) == acceptedSize else {
                throw ShredError.fileChangedDuringShred(displayURL)
            }

            var actualHash = SHA256()
            var readOffset: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while readOffset < acceptedSize {
                let requested = min(buffer.count, Int(acceptedSize - readOffset))
                let count = pread(descriptor, &buffer, requested, off_t(readOffset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ShredError.verificationFailed(displayURL)
                }
                guard count > 0 else {
                    throw ShredError.verificationFailed(displayURL)
                }
                actualHash.update(data: Data(buffer[0..<count]))
                readOffset += Int64(count)
            }
            guard actualHash.finalize() == expectedHash.finalize() else {
                throw ShredError.verificationFailed(displayURL)
            }
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              FileIdentity(finalStatus) == identity,
              Int64(finalStatus.st_size) == acceptedSize
        else {
            throw ShredError.fileChangedDuringShred(displayURL)
        }

        try removePinnedEntry(
            parentFD: parentFD,
            name: name,
            identity: identity,
            displayURL: displayURL,
            isDirectory: false
        )
        Log.deletion(path: displayURL, module: "shredder", disposition: .shred)
        progress?(1)
        return acceptedSize
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        at startingOffset: Int64,
        displayURL: URL
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = pwrite(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written,
                    off_t(startingOffset + Int64(written))
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ShredError.writeFailed(displayURL)
                }
                guard count > 0 else {
                    throw ShredError.writeFailed(displayURL)
                }
                written += count
            }
        }
    }

    private static func removePinnedEntry(
        parentFD: Int32,
        name: String,
        identity: FileIdentity,
        displayURL: URL,
        isDirectory: Bool
    ) throws {
        let currentName = ".macsweep-\(UUID().uuidString)"
        let renameFlags = UInt32(
            RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        )
        guard renameatx_np(parentFD, name, parentFD, currentName, renameFlags) == 0 else {
            throw ShredError.identityChanged(
                displayURL,
                "selected entry changed or could not be renamed: \(posixDescription(errno))"
            )
        }

        var renamedStatus = stat()
        let inspected = fstatat(parentFD, currentName, &renamedStatus, AT_SYMLINK_NOFOLLOW) == 0
        guard inspected, FileIdentity(renamedStatus) == identity else {
            let reason = inspected
                ? "a replacement appeared at the selected name"
                : posixDescription(errno)
            if renameatx_np(parentFD, currentName, parentFD, name, renameFlags) != 0 {
                throw ShredError.identityChanged(
                    displayURL,
                    "\(reason); retained replacement is named \(currentName)"
                )
            }
            throw ShredError.identityChanged(displayURL, reason)
        }

        var finalStatus = stat()
        guard fstatat(parentFD, currentName, &finalStatus, AT_SYMLINK_NOFOLLOW) == 0,
              FileIdentity(finalStatus) == identity
        else {
            throw ShredError.identityChanged(
                displayURL,
                "renamed entry changed before removal and was retained as \(currentName)"
            )
        }

        var flags = AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
        if isDirectory {
            flags |= AT_REMOVEDIR
        } else {
            flags |= AT_UNIQUE
        }
        guard unlinkat(parentFD, currentName, flags) == 0 else {
            let code = errno
            let renameFlags = UInt32(
                RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
            )
            let restored = renameatx_np(
                parentFD,
                currentName,
                parentFD,
                name,
                renameFlags
            ) == 0
            let retainedURL = restored
                ? displayURL
                : displayURL.deletingLastPathComponent().appendingPathComponent(currentName)
            let reason = restored
                ? posixDescription(code)
                : "\(posixDescription(code)); retained under randomized name \(currentName)"
            if isDirectory {
                throw ShredError.cannotRemoveDirectory(retainedURL, reason)
            }
            throw ShredError.cannotRemoveItem(retainedURL, reason)
        }
    }

    private static func addBytes(
        _ bytes: Int64,
        for displayURL: URL,
        context: inout DirectoryContext
    ) {
        guard bytes >= 0 else {
            context.errors.append(.failedToShred(displayURL, "negative shredded byte count"))
            return
        }
        let (sum, overflow) = context.bytesShredded.addingReportingOverflow(bytes)
        if overflow {
            context.bytesShredded = Int64.max
            if !context.reportedOverflow {
                context.reportedOverflow = true
                context.errors.append(.byteCountOverflow(displayURL))
            }
        } else {
            context.bytesShredded = sum
        }
    }

    private static func entryNames(in directoryFD: Int32) throws -> [String] {
        let duplicatedFD = dup(directoryFD)
        guard duplicatedFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let stream = fdopendir(duplicatedFD) else {
            let code = errno
            close(duplicatedFD)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { closedir(stream) }

        rewinddir(stream)
        errno = 0
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name.0) {
                String(cString: $0)
            }
            if name != "." && name != ".." {
                names.append(name)
            }
            errno = 0
        }
        if errno != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return names.sorted()
    }

    private static func openDirectory(path: String, displayURL: URL) throws -> Int32 {
        let descriptor = open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ShredError.refusedSymlink(displayURL)
            }
            throw ShredError.cannotOpenDirectory(displayURL, posixDescription(errno))
        }
        return descriptor
    }

    private static func inspectionError(_ url: URL) -> ShredError {
        if errno == ELOOP {
            return .refusedSymlink(url)
        }
        return .cannotInspectItem(url, posixDescription(errno))
    }

    private static func posixDescription(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func systemAliasNormalized(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for (alias, target) in [
            ("/var", "/private/var"),
            ("/tmp", "/private/tmp"),
            ("/etc", "/private/etc")
        ] {
            if path == alias {
                return URL(fileURLWithPath: target)
            }
            if path.hasPrefix(alias + "/") {
                return URL(fileURLWithPath: target + path.dropFirst(alias.count))
            }
        }
        return URL(fileURLWithPath: path)
    }
}
