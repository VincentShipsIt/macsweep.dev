import Darwin
import Foundation

/// Module for cleaning package manager caches
struct PackageManagerModule: ScanModule {
    let id = "package-managers"
    let name = "Package Managers"
    let description = "Clean Homebrew, npm, pip, cargo, and other package manager caches"
    let icon = "shippingbox"

    /// Cache directories to surface, relative to the user's home. Each is gated by
    /// the shared `scanCacheDirectory` helper (exists + nonzero size). Adding a
    /// package manager is a one-line table entry now, not a copy-pasted block.
    private static let cacheTargets: [(path: String, name: String)] = [
        ("Library/Caches/Homebrew", "Homebrew Cache"),
        ("Library/Logs/Homebrew", "Homebrew Logs"),
        (".npm/_cacache", "npm Cache"),
        (".npm/_logs", "npm Logs"),
        ("Library/Caches/Yarn", "Yarn Cache"),
        (".yarn/cache", "Yarn Berry Cache"),
        ("Library/pnpm/store", "pnpm Store"),
        (".bun/install/cache", "Bun Cache"),
        (".cache/uv", "UV Cache"),
        ("Library/Caches/pip", "pip Cache"),
        (".local/pipx/.cache", "pipx Cache"),
        (".cargo/registry/cache", "Cargo Registry Cache"),
        (".cargo/git/checkouts", "Cargo Git Checkouts"),
        ("Library/Caches/go-build", "Go Build Cache"),
        ("go/pkg/mod/cache", "Go Module Cache"),
        (".composer/cache", "Composer Cache"),
        (".gem/cache", "RubyGems Cache"),
        ("Library/Caches/CocoaPods", "CocoaPods Cache"),
        ("Library/Caches/org.carthage.CarthageKit", "Carthage Cache"),
        (".gradle/caches", "Gradle Cache"),
        (".gradle/wrapper/dists", "Gradle Wrapper Distributions"),
        (".m2/repository", "Maven Repository"),
        // Only the re-fillable download/metadata cache (`~/.cache/mise`). The
        // installed toolchains under `~/.local/share/mise/installs` are deliberately
        // NOT scanned — deleting them removes working runtimes, not cache.
        (".cache/mise", "mise Cache"),
        ("Library/Caches/Mozilla.sccache", "sccache"),
        ("Library/Caches/deno", "Deno Cache")
    ]

    static func overlapsCache(_ path: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let candidate = SafetyChecker.caseNormalized(path.standardizedFileURL.path)
        return cacheTargets.contains {
            let root = SafetyChecker.caseNormalized(home.appendingPathComponent($0.path).standardizedFileURL.path)
            return candidate == root || candidate.hasPrefix(root + "/") || root.hasPrefix(candidate + "/")
        }
    }

    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser
    var processSnapshot: @Sendable () async throws -> DevProcessSnapshot = { try await DevProcessActivity.snapshot() }
    var toolPath: @Sendable (String) -> String? = { name in
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".bun/bin/\(name)").path,
            home.appendingPathComponent(".local/bin/\(name)").path,
            HomebrewPaths.toolPath(name)
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var commandRunner: PackageCacheCommandRunner = { executable, arguments in
        try await ProcessRunner.run(
            executable: executable, arguments: arguments,
            currentDirectory: URL(fileURLWithPath: "/"), timeout: 15)
    }
    var remove: @Sendable (URL) throws -> Void = {
        try CleanupFileRemover.recoverable($0, module: "package-managers")
    }

    func scan() async throws -> [CleanupItem] {
        let snapshot = try await processSnapshot()
        var items: [CleanupItem] = []
        for target in Self.cacheTargets {
            try Task.checkCancellation()
            let path = homeDirectory.appendingPathComponent(target.path)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            do {
                let measured = try await DevArtifactIO.run { try DevArtifactContent.measure(path) }
                guard measured.size > 0 else { continue }
                let manager = Self.manager(for: target.path)
                let receipt = try await assess(path, manager: manager, snapshot: snapshot)
                items.append(
                    CleanupItem(
                        id: UUID(), path: path, size: measured.size, type: .directory,
                        module: id, moduleName: target.name, lastModified: measured.modified,
                        cleanupReviewReason: receipt.retentionReason, managedCleanupReceipt: receipt))
            } catch is CancellationError { throw CancellationError() } catch {
                ScanDiagnostics.current?.record(error, at: path)
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    private static func manager(for relative: String) -> String {
        if relative.hasPrefix(".m2/") { return "mvn" }
        if relative == ".cache/uv" { return "uv" }
        if relative == ".bun/install/cache" { return "bun" }
        if relative.hasPrefix(".npm/") { return "npm" }
        if relative.contains("Homebrew") { return "brew" }
        if relative.contains("pnpm") { return "pnpm" }
        if relative.contains("Yarn") || relative.hasPrefix(".yarn/") { return "yarn" }
        for (fragment, name) in [
            ("pipx", "pipx"), ("pip", "pip"), ("CocoaPods", "pod"),
            ("carthage", "carthage"), ("go-", "go"), ("sccache", "sccache"), ("deno", "deno")
        ] where relative.localizedCaseInsensitiveContains(fragment) { return name }
        return relative.split(separator: "/").first.map { String($0).replacingOccurrences(of: ".", with: "") } ?? ""
    }

    private func assess(_ path: URL, manager: String, snapshot: DevProcessSnapshot) async throws
        -> ManagedCleanupReceipt {
        let identity = try await DevArtifactIO.run { try ManagedCleanupEvidence.identity(path) }
        var nodes: [DevArtifactNode] = []
        var reason: String?
        do { nodes = try await DevArtifactIO.run { try ManagedCleanupEvidence.nodes(path, module: id) } } catch {
            reason = error.localizedDescription
        }
        let blockers = ManagedCleanupEvidence.blockers(snapshot, path: path, manager: manager)
        reason = reason ?? ManagedCleanupEvidence.activityReason(snapshot, blockers: blockers)
        var operation: ManagedCleanupOperation = .trash
        var preview = "Move this cache to Trash; restore until Trash is emptied. Downloads/builds may recur."
        if manager == "uv" || manager == "bun" {
            preview =
                "Native \(manager) prune permanently removes eligible entries; no Trash recovery. "
                + "Cache size is an upper bound, not promised reclaimed space. Future installs may download/rebuild."
            do {
                operation = try await nativeOperation(manager: manager)
                if manager == "uv" {
                    try await DevArtifactIO.run { try protectUVEnvironments(cache: path) }
                }
            } catch { reason = reason ?? error.localizedDescription }
            if manager == "uv" {
                preview +=
                    " UV prune is skipped when cached environments or installed-tool links need this cache. "
                    + "Installed runtimes are outside scope."
            } else {
                preview +=
                    " Bun retains links/global store, Git clones and manifests; "
                    + "only packages older than 30 days are pruned."
            }
        }
        if operation.isNative {
            preview +=
                " Command: "
                + ([operation.executable ?? ""] + operation.arguments(path: path)).map {
                    "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }.joined(separator: " ")
        }
        return ManagedCleanupReceipt(
            identity: identity, nodes: nodes, operation: operation,
            preview: "Owner: \(manager) (uid \(getuid())). " + preview, blockers: blockers, retentionReason: reason)
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processed = 0
        var bytes: Int64 = 0
        var errors: [CleanupError] = []
        var actions: [UUID: CleanupHistoryAction] = [:]
        for item in items where item.module == id {
            do {
                try Task.checkCancellation()
                guard
                    let target = Self.cacheTargets.first(where: {
                        homeDirectory.appendingPathComponent($0.path).standardizedFileURL
                            == item.path.standardizedFileURL
                    }), let receipt = item.managedCleanupReceipt, receipt.isEligible,
                    SafetyChecker().validateForCleanup(item, moduleID: id).isSafe
                else {
                    throw DevArtifactSafetyError(
                        item.cleanupReviewReason ?? "Missing eligible package-cache receipt. Rescan first.")
                }
                try await DevArtifactIO.run {
                    try ManagedCleanupEvidence.validate(receipt, path: item.path, module: id)
                }
                let current = try await assess(
                    item.path, manager: Self.manager(for: target.path), snapshot: try await processSnapshot())
                guard current.isEligible, current.operation == receipt.operation else {
                    throw DevArtifactSafetyError(current.retentionReason ?? "Manager capability changed. Rescan first.")
                }
                try await DevArtifactIO.run {
                    try ManagedCleanupEvidence.validate(receipt, path: item.path, module: id)
                }
                let activity = try await processSnapshot()
                let blockers = ManagedCleanupEvidence.blockers(
                    activity, path: item.path,
                    manager: Self.manager(for: target.path))
                if let reason = ManagedCleanupEvidence.activityReason(activity, blockers: blockers) {
                    throw DevArtifactSafetyError(reason)
                }
                if !dryRun { actions[item.id] = try await execute(receipt.operation, path: item.path) }

                processed += 1
                // Prune does not promise removal of the entire inventory. Never credit its full scanned size.
                if !receipt.operation.isNative { bytes += item.size }
            } catch {
                let message =
                    error is CancellationError
                    ? "Cancelled; an interrupted native prune may have changed entries. Rescan before retrying."
                    : error.localizedDescription
                errors.append(CleanupError(path: item.path, message: message, underlyingError: error))
            }
        }
        return CleanupResult(itemsProcessed: processed, bytesFreed: bytes, errors: errors, historyActions: actions)
    }

}

// MARK: - Package Manager Info

struct PackageManagerInfo: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: String
    var cacheSize: Int64 = 0
    var cacheItems: [CleanupItem] = []

    var formattedSize: String {
        cacheSize.formattedFileSize
    }

    static let all: [PackageManagerInfo] = [
        PackageManagerInfo(id: "homebrew", name: "Homebrew", icon: "cup.and.saucer", color: "orange"),
        PackageManagerInfo(id: "npm", name: "npm", icon: "cube.box", color: "red"),
        PackageManagerInfo(id: "yarn", name: "Yarn", icon: "cube.box.fill", color: "blue"),
        PackageManagerInfo(id: "pnpm", name: "pnpm", icon: "shippingbox", color: "yellow"),
        PackageManagerInfo(id: "bun", name: "Bun", icon: "bolt", color: "pink"),
        PackageManagerInfo(id: "uv", name: "UV", icon: "bolt.circle", color: "purple"),
        PackageManagerInfo(id: "pip", name: "pip", icon: "cube", color: "blue"),
        PackageManagerInfo(id: "cargo", name: "Cargo", icon: "gearshape.2", color: "orange"),
        PackageManagerInfo(id: "go", name: "Go", icon: "figure.run", color: "cyan"),
        PackageManagerInfo(id: "composer", name: "Composer", icon: "music.note", color: "brown"),
        PackageManagerInfo(id: "gem", name: "RubyGems", icon: "diamond", color: "red"),
        PackageManagerInfo(id: "cocoapods", name: "CocoaPods", icon: "leaf", color: "red"),
        PackageManagerInfo(id: "carthage", name: "Carthage", icon: "cart", color: "blue"),
        PackageManagerInfo(id: "gradle", name: "Gradle", icon: "elephant", color: "green"),
        PackageManagerInfo(id: "maven", name: "Maven", icon: "m.circle", color: "red"),
        PackageManagerInfo(id: "mise", name: "mise", icon: "arrow.triangle.2.circlepath", color: "green"),
        PackageManagerInfo(id: "sccache", name: "sccache", icon: "bolt.horizontal", color: "orange"),
        PackageManagerInfo(id: "deno", name: "Deno", icon: "lizard", color: "gray")
    ]
}
