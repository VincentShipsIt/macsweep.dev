import Darwin
import Foundation

struct StaleProjectArchive: Sendable {
    var policy = StaleProjectPolicy()
    var runner: StaleProjectCommandRunner = { executable, arguments, timeout in
        try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
    }

    var checker: @Sendable () -> SafetyChecker = { SafetyChecker() }

    func create(_ project: StaleProject, destination: URL) async throws -> StaleArchiveReceipt {
        let cancellation = StaleProjectCancellation()
        return try await withTaskCancellationHandler {
            try await create(project, destination: destination, cancellation: cancellation)
        } onCancel: { cancellation.cancel() }
    }

    private func create(
        _ project: StaleProject, destination: URL, cancellation: StaleProjectCancellation,
    ) async throws -> StaleArchiveReceipt {
        guard project.archiveBlocker == nil, let identity = project.identity else {
            throw DevArtifactSafetyError(project.archiveBlocker ?? "Checkout identity is unavailable.")
        }
        let source = project.path
        let before = try await manifest(source, cancellation: cancellation)
        guard before.identity == identity else { throw DevArtifactSafetyError("Checkout changed; rescan first.") }
        let workspace = try await DevArtifactIO.commit {
            try prepare(destination, source: source, cancellation: cancellation)
        }
        let workspaceIdentity = try DevArtifactIdentity.read(workspace)
        defer {
            if (try? DevArtifactIdentity.read(workspace)) == workspaceIdentity {
                try? FileManager.default.removeItem(at: workspace)
            }
        }
        let zip = workspace.appending(path: "archive.zip")
        try await command("/usr/bin/ditto", [
            "-c", "-k", "--sequesterRsrc", "--rsrc", "--extattr", "--acl", "--qtn", "--keepParent",
            source.path, zip.path
        ])
        guard try await manifest(source, cancellation: cancellation) == before else {
            throw DevArtifactSafetyError(
                "Checkout changed while copying. Archive extraction was skipped; source retained.")
        }
        try await verify(zip, source: source, original: before, workspace: workspace, cancellation: cancellation)
        guard try await manifest(source, cancellation: cancellation) == before else {
            throw DevArtifactSafetyError("Checkout changed while archiving. Original source was retained.")
        }
        let state = await StaleProjectGit.inspect(source)
        let blocker = before.containsNestedGit
            ? "Nested Git repositories require manual checkout management."
            : state.trashBlocker ?? checker().validateForTrash(source).reason
        let seal = try await DevArtifactIO
            .commit { try publish(zip, destination: destination, cancellation: cancellation) }
        return StaleArchiveReceipt(
            project: project, destination: destination, manifest: before,
            archiveIdentity: seal.identity, archiveStamp: seal.stamp, archiveDigest: seal.digest,
            archiveBytes: seal.bytes,
            trashBlocker: blocker,
        )
    }

    func validate(
        _ receipt: StaleArchiveReceipt, cancellation: StaleProjectCancellation? = nil,
    ) async throws {
        try await DevArtifactIO.run {
            var status = stat()
            guard try ManagedCleanupEvidence.identity(receipt.destination) == receipt.archiveIdentity,
                  lstat(receipt.destination.path, &status) == 0,
                  DevArtifactNode(path: receipt.destination.path, status: status) == receipt.archiveStamp,
                  try StaleProjectManifest.digest(
                      receipt.destination, deadline: ProcessInfo.processInfo.systemUptime + policy.manifestTimeLimit,
                      cancellation: cancellation,
                  )
                  == receipt.archiveDigest
            else {
                throw DevArtifactSafetyError("Verified archive changed or is unavailable; checkout retained.")
            }
        }
        guard try await manifest(receipt.project.path, cancellation: cancellation) == receipt.manifest else {
            throw DevArtifactSafetyError("Checkout changed after archiving; create a new backup before Trash.")
        }
    }

    private func manifest(
        _ root: URL, cancellation: StaleProjectCancellation? = nil,
    ) async throws -> StaleProjectManifest {
        try await DevArtifactIO.run {
            try StaleProjectManifest.capture(root, policy: policy, checker: checker(), cancellation: cancellation)
        }
    }

    private func verify(
        _ zip: URL, source: URL, original: StaleProjectManifest, workspace: URL,
        cancellation: StaleProjectCancellation,
    ) async throws {
        try await command("/usr/bin/unzip", ["-tqq", zip.path])
        let extracted = workspace.appending(path: "roundtrip")
        try await command(
            "/usr/bin/ditto",
            ["-x", "-k", "--rsrc", "--extattr", "--acl", "--qtn", zip.path, extracted.path],
        )
        let copy = try await DevArtifactIO.run {
            try StaleProjectManifest.capture(
                extracted.appending(path: source.lastPathComponent), policy: policy,
                checker: SafetyChecker(userRules: .empty), cancellation: cancellation,
            )
        }
        guard original.matchesCopy(copy) else {
            throw DevArtifactSafetyError("Archive round-trip contents or metadata did not match. Source was retained.")
        }
    }

    private func command(_ executable: String, _ arguments: [String]) async throws {
        try Task.checkCancellation()
        let result = try await runner(executable, arguments, 300)
        guard result.didSucceed else {
            throw DevArtifactSafetyError("Archive command failed (status \(result.status)); source was retained.")
        }
    }

    private func prepare(
        _ destination: URL, source: URL, cancellation: StaleProjectCancellation
    ) throws -> URL {
        let parent = destination.deletingLastPathComponent()
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
              destination.pathExtension.lowercased() == "zip", destination.path.utf8.count < 4096,
              parent.resolvingSymlinksInPath().path == parent.standardizedFileURL.path,
              !DevArtifactPaths.contains(
                  source.resolvingSymlinksInPath(),
                  parent.resolvingSymlinksInPath().appending(path: destination.lastPathComponent),
              ),
              !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.isWritableFile(atPath: parent.path)
        else {
            throw DevArtifactSafetyError("Choose a new ZIP outside the checkout in a writable, real directory.")
        }
        // lstat also rejects dangling destination links, which fileExists intentionally follows.
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else {
            throw DevArtifactSafetyError("The archive destination already exists; it will not be overwritten.")
        }
        let workspace = parent.appending(path: ".macsweep-archive-" + UUID().uuidString)
        try cancellation.check()
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700],
        )
        return workspace
    }

    private struct Seal {
        let identity: DevArtifactIdentity
        let stamp: DevArtifactNode
        let digest: String
        let bytes: Int64
    }

    private func publish(
        _ zip: URL, destination: URL, cancellation: StaleProjectCancellation,
    ) throws -> Seal {
        let identity = try ManagedCleanupEvidence.identity(zip)
        var info = stat()
        guard identity.type == S_IFREG, lstat(zip.path, &info) == 0, info.st_size > 0 else {
            throw DevArtifactSafetyError("Archive is empty or unreadable; source retained.")
        }
        let digest = try StaleProjectManifest.digest(
            zip, deadline: ProcessInfo.processInfo.systemUptime + policy.manifestTimeLimit, cancellation: cancellation,
        )
        try cancellation.check()
        // RENAME_EXCL publishes atomically without a replacement race at the user-selected destination.
        guard renamex_np(zip.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw DevArtifactSafetyError("Archive destination changed or could not be published; source retained.")
        }
        guard lstat(destination.path, &info) == 0
        else { throw DevArtifactSafetyError("Published archive unavailable.") }
        return try Seal(identity: ManagedCleanupEvidence.identity(destination),
                        stamp: DevArtifactNode(path: destination.path, status: info), digest: digest,
                        bytes: Int64(info.st_size))
    }
}
