import Darwin
import Foundation

enum AuthorizedFileEvidence {
    static func read(_ path: URL, maximumBytes: Int, expected: DevArtifactNode? = nil) throws -> Data {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DevArtifactSafetyError("Reviewed file could not be opened safely.") }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0, before.st_size <= maximumBytes
        else {
            throw DevArtifactSafetyError("Reviewed file is not regular or exceeds its read budget.")
        }
        let witness = DevArtifactNode(path: path.path, status: before)
        if let expected, witness != expected { throw DevArtifactSafetyError("Reviewed file changed.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        var after = stat()
        guard data.count <= maximumBytes, data.count == before.st_size,
            lstat(path.path, &after) == 0, DevArtifactNode(path: path.path, status: after) == witness
        else {
            throw DevArtifactSafetyError("Reviewed file changed while it was read.")
        }
        return data
    }
}
