import CryptoKit
import Darwin
import Foundation

enum StaleProjectMetadata {
    /// Seal xattrs (including resource forks), ACLs, ownership and flags in addition to file contents.
    static func digest(_ url: URL, status: stat) throws -> String {
        let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard length >= 0, length <= 65536 else { throw unavailable() }
        var names = [UInt8](repeating: 0, count: max(1, length))
        guard listxattr(url.path, &names, length, XATTR_NOFOLLOW) == length else { throw unavailable() }
        var hasher = SHA256()
        var total = 0
        for bytes in names.prefix(length).split(separator: 0).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let name = String(bytes: bytes, encoding: .utf8) else { throw unavailable() }
            let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0, size <= 16_777_216 - total else { throw unavailable() }
            var value = [UInt8](repeating: 0, count: max(1, size))
            guard getxattr(url.path, name, &value, size, 0, XATTR_NOFOLLOW) == size else { throw unavailable() }
            total += size
            hasher.update(data: Data("\(name.utf8.count):\(size):".utf8))
            hasher.update(data: Data(name.utf8))
            hasher.update(data: Data(value.prefix(size)))
        }
        let acl = try aclData(url, status: status)
        hasher.update(data: Data("ACL:\(acl.count):".utf8))
        hasher.update(data: acl)
        hasher.update(data: Data("\(status.st_uid):\(status.st_gid):\(status.st_flags)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func aclData(_ url: URL, status: stat) throws -> Data {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            // Darwin reports ENOENT for a valid vnode with no extended ACL, too.
            let failure = errno
            var fresh = stat()
            guard failure == ENOENT, lstat(url.path, &fresh) == 0,
                  DevArtifactNode(path: url.path, status: fresh) == DevArtifactNode(path: url.path, status: status)
            else { throw unavailable() }
            return Data()
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var textLength = 0
        guard let text = acl_to_text(acl, &textLength), textLength <= 65536 else { throw unavailable() }
        defer { acl_free(text) }
        return Data(bytes: text, count: textLength)
    }

    private static func unavailable() -> DevArtifactSafetyError {
        DevArtifactSafetyError("Complete extended attributes or permissions are unavailable; source retained.")
    }
}
