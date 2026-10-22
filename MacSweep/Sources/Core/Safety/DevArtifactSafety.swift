import Darwin
import Foundation

struct DevArtifactSafety: Sendable {
    var processSnapshot: @Sendable () async throws -> DevProcessSnapshot = { try await DevProcessActivity.snapshot() }
    var git: @Sendable ([String], URL) async -> ProcessResult = { arguments, directory in
        if arguments.first == "ls-files" {
            do {
                return try await ProcessRunner.runPipeline(
                    stages: [
                        ProcessPipelineStage(
                            executable: "/usr/bin/git",
                            arguments: ["--literal-pathspecs", "-C", directory.path] + arguments),
                        ProcessPipelineStage(executable: "/usr/bin/head", arguments: ["-c", "1"])
                    ], timeout: 5)
            } catch {
                return ProcessResult(status: -1, output: "", error: error.localizedDescription)
            }
        }
        return await GitArtifactScanner.run(["git", "-C", directory.path] + arguments, timeout: 5)
    }
    var libraryDirectory: URL = .libraryDirectory

    func assess(
        _ url: URL, expected: DevArtifactIdentity? = nil,
        processes: DevProcessSnapshot? = nil, checker: SafetyChecker = SafetyChecker()
    ) async -> DevArtifactReceipt {
        var identity: DevArtifactIdentity?
        var project = url.deletingLastPathComponent()
        var blockers: [DevProcessJob] = []
        var projectType: ProjectType?
        var gitEvidence: DevArtifactGitEvidence?
        do {
            identity = try await DevArtifactIO.run { try DevArtifactIdentity.read(url) }
            if let expected, expected != identity {
                throw DevArtifactSafetyError("Target or parent identity changed since scanning. Rescan first.")
            }
            let owner = try await verifyOwnership(url, identity: identity)
            project = owner.project
            projectType = owner.type
            gitEvidence = owner.gitEvidence
            let content = try await DevArtifactIO.run {
                try DevArtifactContent.validateTree(
                    url, genericOutput: ["dist", "build"].contains(url.lastPathComponent), checker: checker)
            }
            let snapshot: DevProcessSnapshot
            if let processes { snapshot = processes } else { snapshot = try await processSnapshot() }
            blockers = snapshot.blockers(target: url, project: project)
            guard snapshot.issues.isEmpty else {
                throw DevArtifactSafetyError(
                    "Activity inspection is incomplete: " + snapshot.issues.prefix(3).joined(separator: "; "))
            }
            guard blockers.isEmpty else {
                throw DevArtifactSafetyError(
                    "In use by " + blockers.map(\.label).joined(separator: ", ")
                        + ". Stop verified jobs separately, then rescan.")
            }
            let capturedGit = gitEvidence
            guard
                try await DevArtifactIO.run({
                    try capturedGit?.validate()
                    return try DevArtifactIdentity.read(url)
                }) == identity
            else {
                throw DevArtifactSafetyError("Target identity changed during inspection.")
            }
            return DevArtifactReceipt(
                identity: identity, project: project,
                reason: "Verified generated content; no current-user job uses this target. Cleanup moves it to Trash.",
                blockers: [], isEligible: true, content: content, projectType: projectType,
                gitEvidence: gitEvidence)
        } catch {
            return DevArtifactReceipt(
                identity: identity, project: project, reason: error.localizedDescription,
                blockers: blockers, isEligible: false, projectType: projectType)
        }
    }

    private struct Owner {
        let project: URL
        let type: ProjectType?
        let gitEvidence: DevArtifactGitEvidence?
    }

    private func verifyOwnership(_ url: URL, identity: DevArtifactIdentity?) async throws -> Owner {
        let pattern = try await DevArtifactIO.run { DevArtifactPattern.allPatterns.first { $0.matches(url) } }
        let fixed = Self.fixedTargets(in: libraryDirectory).first {
            $0.path.standardizedFileURL.path == url.standardizedFileURL.path
        }
        guard pattern != nil || fixed != nil else {
            throw DevArtifactSafetyError("The target is not a recognized developer artifact.")
        }
        var project = url.deletingLastPathComponent()
        var gitEvidence: DevArtifactGitEvidence?
        if let fixed {
            guard identity?.type == S_IFDIR else {
                throw DevArtifactSafetyError("Developer cache filesystem type changed.")
            }
            guard fixed.disposable else {
                throw DevArtifactSafetyError("Use the owning developer tool to review this persistent data.")
            }
            project = url
        } else {
            guard let pattern else { throw DevArtifactSafetyError("Artifact ownership is unavailable.") }
            guard identity?.type == (pattern.fileExtension == nil ? S_IFDIR : S_IFREG) else {
                throw DevArtifactSafetyError("Artifact filesystem type changed.")
            }
            let proof = try await generatedEvidence(for: url)
            project =
                try await DevArtifactIO.run {
                    try DevArtifactContent.projectRoot(from: url.deletingLastPathComponent())
                } ?? proof.repositoryRoot
            gitEvidence = proof
            if pattern.fileExtension != nil {
                guard try await DevArtifactIO.run({ try DevArtifactContent.isTypeScriptBuildInfo(url) }) else {
                    throw DevArtifactSafetyError(
                        "The file does not contain recognized TypeScript build information.")
                }
            }
        }
        return Owner(project: project, type: pattern?.projectType, gitEvidence: gitEvidence)
    }

    private func generatedEvidence(for url: URL) async throws -> DevArtifactGitEvidence {
        let repository = await git(["rev-parse", "--show-toplevel"], url.deletingLastPathComponent())
        guard repository.didSucceed else {
            throw DevArtifactSafetyError(
                "Generated content cannot be verified without a readable Git repository.")
        }
        let root = URL(fileURLWithPath: repository.output.trimmingCharacters(in: .whitespacesAndNewlines))
        guard DevArtifactPaths.contains(root, url),
            url.standardizedFileURL.path != root.standardizedFileURL.path
        else {
            throw DevArtifactSafetyError("Artifact is outside its repository.")
        }
        let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        let metadata = await git(["rev-parse", "--absolute-git-dir"], root)
        let excludes = await git(["config", "--path", "--get", "core.excludesfile"], root)
        guard metadata.didSucceed, excludes.didSucceed || excludes.status == 1 else {
            throw DevArtifactSafetyError("Git metadata and ignore configuration are unavailable.")
        }
        let metadataURL = URL(fileURLWithPath: metadata.output.trimmingCharacters(in: .newlines))
        let excludesPath = excludes.output.trimmingCharacters(in: .newlines)
        let excludesURL = excludesPath.isEmpty ? nil : URL(fileURLWithPath: excludesPath, relativeTo: root)
        let evidence = try await DevArtifactIO.run {
            try DevArtifactGitEvidence.capture(
                paths: DevArtifactGitEvidence.paths(
                    root: root, metadata: metadataURL, target: url, excludes: excludesURL), repositoryRoot: root)
        }
        for args in [
            ["ls-files", "-z", "--cached", "--", relative],
            ["ls-files", "-z", "--others", "--exclude-standard", "--", relative]
        ] {
            let result = await git(args, root)
            guard result.didSucceed, result.outputWasValidUTF8, result.output.isEmpty else {
                throw DevArtifactSafetyError(
                    "Tracked or uncommitted user content is retained; "
                        + "the target needs a clean generated-content boundary."
                )
            }
        }
        let ignored = await git(["check-ignore", "-q", "--", relative], root)
        guard ignored.didSucceed else {
            throw DevArtifactSafetyError(
                "Artifact is not explicitly ignored by Git; its name alone is insufficient.")
        }
        return evidence
    }

    struct FixedTarget: Sendable {
        let path: URL
        let name: String
        let disposable: Bool
    }

    static func fixedTargets(in library: URL) -> [FixedTarget] {
        [
            ("Developer/Xcode/DerivedData", "Xcode DerivedData", true),
            ("Developer/Xcode/Archives", "Xcode Archives", false),
            ("Developer/Xcode/iOS DeviceSupport", "iOS Device Support", false),
            ("Caches/ms-playwright", "Playwright Browsers", true),
            ("Developer/CoreSimulator/Devices", "iOS Simulators", false)
        ].map { FixedTarget(path: library.appendingPathComponent($0.0), name: $0.1, disposable: $0.2) }
    }
}
