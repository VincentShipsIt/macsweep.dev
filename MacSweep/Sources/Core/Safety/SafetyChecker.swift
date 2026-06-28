import Foundation

/// Safety validation to prevent accidental deletion of critical files.
///
/// Design: **default-deny**. A path is only ever cleaned if it positively
/// matches a known-safe zone. Anything unrecognized resolves to `.unknown`,
/// which `isSafe` treats as *unsafe*. The validation order is deliberate:
///
///   1. Standardize the URL (collapses `..`/`.`) — closes path-traversal escapes.
///   2. Sensitive filename patterns (keys, creds, db files) — always block.
///   3. Symlinks pointing outside home — always block.
///   4. Module-scoped carve-outs for user-managed and cloud roots (profile-gated).
///   5. Longest-prefix arbitration between `neverDelete` and `safeCacheRoots`
///      (the more-specific path wins, so `/var/folders` beats `/var`).
///   6. Explicit module allow-zones (package-manager caches, trash, privacy).
///   7. Generic safe directory names (Cache/node_modules/DerivedData/…).
///   8. Default: `.unknown` (denied).
struct SafetyChecker: Sendable {

    // Module IDs that own explicit allow-zones below.
    private static let trashModuleID = "trash-bins"
    private static let privacyModuleID = "privacy"
    private static let aiAnalysisModuleID = "ai-analysis"
    private static let packageManagerModuleIDs: Set<String> = ["package-managers", "dev-tools"]

    // MARK: - Validation

    func validate(_ url: URL) -> ValidationResult {
        validateForCleanup(url)
    }

    func validateForScan(_ url: URL, moduleID: String? = nil) -> ValidationResult {
        validate(url, context: .scan(moduleID: moduleID, itemType: nil))
    }

    func validateForCleanup(
        _ url: URL,
        moduleID: String? = nil,
        itemType: CleanupItem.ItemType? = nil
    ) -> ValidationResult {
        validate(url, context: .cleanup(moduleID: moduleID, itemType: itemType))
    }

    /// Validate a path the user has *explicitly* selected for secure shredding.
    ///
    /// Unlike `validateForCleanup`, this is a **blocklist**, not a default-deny
    /// allowlist. The shredder's whole purpose is destroying arbitrary
    /// user-chosen files — including documents and the very credential files a
    /// user most wants gone — so an unrecognized path is *allowed*. We still
    /// refuse the catastrophic targets:
    ///   • symlinks (overwriting follows the link and destroys its target);
    ///   • the home directory or filesystem root themselves;
    ///   • an entire user document root (e.g. all of ~/Documents);
    ///   • the system / app-data / credential / cloud roots in `neverDelete`.
    /// Files *inside* the user document roots stay shreddable.
    func validateForShred(_ url: URL) -> ValidationResult {
        validateBlocklist(url, action: .shred)
    }

    /// Validate a path the user has *explicitly* selected to move to the Trash from
    /// an arbitrary location (e.g. the Space Lens disk map). Like `validateForShred`
    /// this is a **blocklist**, not the default-deny cleanup allowlist: an
    /// unrecognized user path is allowed (that is the feature), but the
    /// system/app-data/credential/cloud roots and whole user-folder roots stay
    /// protected. The action is recoverable (Trash), but still gated so a stray
    /// click — or a parent symlink pointing into a protected root — can't nuke a
    /// critical path.
    func validateForTrash(_ url: URL) -> ValidationResult {
        validateBlocklist(url, action: .trash)
    }

    private enum BlocklistAction {
        case shred, trash
        var verb: String { self == .shred ? "shred" : "move to Trash" }
    }

    /// Shared blocklist used by shred and explicit move-to-Trash. The shredder's and
    /// disk-map's whole purpose is acting on arbitrary user-chosen files, so an
    /// unrecognized path is *allowed*; we only refuse the catastrophic targets.
    private func validateBlocklist(_ url: URL, action: BlocklistAction) -> ValidationResult {
        let standardized = url.standardized

        // Never follow a symlink as the FINAL component: a write/overwrite opens
        // through it and would destroy the link target's bytes, not the link the
        // user selected.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: standardized.path)) != nil {
            return .symlink(reason: "Symlink — would affect the link target, not the link")
        }

        // Evaluate protections against the REAL target: resolve parent-directory
        // symlinks so a path whose *parent* links into a protected root (e.g.
        // ~/link/secret where `link` -> /System) cannot masquerade as an
        // unrecognized-but-safe path while the op follows the link to the real file.
        let path = Self.realParentPath(url)

        // Refuse the filesystem root and the home directory itself.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardized.path
        if path == "/" || path == home {
            return .protected(reason: "Refusing to \(action.verb) the home directory or filesystem root")
        }

        // Carve out the user document roots so files *inside* them are allowed, but
        // refuse a request to act on a whole root folder (e.g. all of ~/Documents).
        for root in ProtectedPaths.userManagedRoots where path == expandedPathValue(for: root) {
            return .protected(reason: "Refusing to \(action.verb) an entire user folder")
        }
        if isUnder(path, anyOf: ProtectedPaths.userManagedRoots) {
            return .safe
        }

        // Everything else in neverDelete (system dirs, app data, credential dirs,
        // cloud roots) is off-limits even for an explicit user action.
        if isUnder(path, anyOf: ProtectedPaths.neverDelete) {
            return .protected(reason: "System, application-data, or credential path")
        }

        // Arbitrary user-selected file outside every protected root: allowed.
        return .safe
    }

    private func validate(_ url: URL, context: ValidationContext) -> ValidationResult {
        // 1. Standardize first. This collapses `..`/`.` segments so that a path
        //    like `~/Library/Caches/../../Documents/secret.txt` is evaluated as
        //    `~/Documents/secret.txt` and cannot escape into a protected root.
        let standardized = url.standardized
        // Resolve PARENT-directory symlinks so every protection/allow decision is
        // made against the real target a delete would actually hit. Without this a
        // path like ~/link/Cache/x (with `link` -> /System) matches no protected
        // prefix lexically yet `removeItem` follows the link and deletes the real
        // file. The final component is left unresolved (a final-component symlink is
        // handled at step 3 below).
        let path = Self.realParentPath(url)
        let components = (path as NSString).pathComponents
        let profile = ModuleSafetyProfile(moduleID: context.moduleID)

        // 2. Sensitive file patterns (keys, credentials, databases) — block always,
        //    regardless of module or location.
        let filename = standardized.lastPathComponent.lowercased()
        for pattern in ProtectedPaths.sensitivePatterns {
            if matchesPattern(filename, pattern: pattern) {
                return .sensitive(pattern: pattern)
            }
        }

        // 3. Symlink escaping the home directory — block always.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: standardized.path)) != nil {
            if !isSymlinkSafe(standardized) {
                return .symlink(reason: "Points outside home directory")
            }
        }

        // 4. Module-scoped carve-outs for user-managed roots (~/Documents, ~/Pictures…)
        //    and cloud roots. Checked BEFORE neverDelete because these roots also
        //    appear in neverDelete; only an explicitly opted-in module may proceed.
        if isUnder(path, anyOf: ProtectedPaths.userManagedRoots) {
            switch context.mode {
            case .scan where profile.allowsUserManagedScan: return .safe
            case .cleanup where profile.allowsUserManagedCleanup: return .safe
            default: break
            }
        }

        if isUnder(path, anyOf: ProtectedPaths.cloudRoots) {
            switch context.mode {
            case .scan where profile.allowsCloudScan: return .safe
            case .cleanup where profile.allowsCloudCleanup: return .safe
            default: break
            }
        }

        // 5. Longest-prefix arbitration: a path may sit under both a protected root
        //    and a safe-cache root (e.g. /private/var/folders is inside /private).
        //    The more-specific (longer) match wins. Protected wins ties.
        let protectedLen = longestPrefixLength(path, in: ProtectedPaths.neverDelete)
        let safeCacheLen = longestPrefixLength(path, in: ProtectedPaths.safeCacheRoots)
        if safeCacheLen > protectedLen {
            return .safe
        }
        if protectedLen >= 0 {
            return .protected(reason: "System or user critical path")
        }

        // 6. Explicit module allow-zones (only reached when NOT under any protected
        //    root, so these cannot be abused to escape neverDelete).

        // 6a. Package-manager caches that live outside ~/Library/Caches
        //     (~/.npm/_cacache, ~/Library/pnpm/store, ~/.m2/repository, …).
        if let moduleID = context.moduleID,
           Self.packageManagerModuleIDs.contains(moduleID),
           isUnder(path, anyOf: ProtectedPaths.packageManagerCacheRoots) {
            return .safe
        }

        // 6b. Trash bins — only the trash module may empty them.
        if context.moduleID == Self.trashModuleID,
           components.contains(".Trash") || components.contains(".Trashes") {
            return .safe
        }

        // 6c. Privacy artifacts — recent-file lists and Safari download history.
        if context.moduleID == Self.privacyModuleID, isPrivacyArtifact(path) {
            return .safe
        }

        // 6d. AI-Analysis / CacheAnalyzer findings: developer + AI-tool caches and
        //     logs that live OUTSIDE ~/Library/Caches and so aren't covered by
        //     safeCacheRoots/safeDirectoryNames (~/.npm/_npx, ~/.cache/pip,
        //     ~/.claude/debug, ~/.codex/log, …). Only the AI-analysis cleanup may
        //     remove them, and only the exact roots CacheAnalyzer surfaces. None
        //     overlap a neverDelete root (already arbitrated at step 5).
        if context.moduleID == Self.aiAnalysisModuleID,
           isUnder(path, anyOf: ProtectedPaths.aiAnalysisCacheRoots)
               || isUnder(path, anyOf: ProtectedPaths.packageManagerCacheRoots) {
            return .safe
        }

        // 7. Generic safe directory names (Cache/GPUCache/node_modules/DerivedData…).
        //    Safe here because any path under a protected root already returned at
        //    step 5; this only matches caches in non-protected locations.
        if !ProtectedPaths.safeDirectoryNames.isDisjoint(with: Set(components)) {
            return .safe
        }

        // 8. Default-deny.
        return .unknown(reason: "Path not in known safe or protected lists")
    }

    func validateBatch(_ urls: [URL], moduleID: String? = nil) -> [URL: ValidationResult] {
        var results: [URL: ValidationResult] = [:]
        for url in urls {
            results[url] = validate(url, context: .cleanup(moduleID: moduleID, itemType: nil))
        }
        return results
    }

    // MARK: - Helpers

    private func expandedPathValue(for protectedPath: String) -> String {
        protectedPath.expandingTilde
    }

    /// `url` with parent-directory symlinks resolved, so protection checks see the
    /// real target a destructive op would actually hit. The final path component is
    /// deliberately NOT resolved — a final-component symlink is handled separately,
    /// and resolving it could turn a refusable link into its (possibly safe-looking)
    /// target. Non-existent parent components are left as-is.
    private static func realParentPath(_ url: URL) -> String {
        let standardized = url.standardized
        if standardized.path == "/" { return "/" }
        let fm = FileManager.default
        let lastComponent = standardized.lastPathComponent

        // `resolvingSymlinksInPath` only resolves a path whose full target exists, so
        // for a not-yet-existent leaf it would leave a symlinked PARENT unresolved.
        // Resolve the deepest EXISTING ancestor directory and re-append the missing
        // tail, so ~/link/Cache/x (link -> /System) resolves even when Cache/x is
        // absent on disk.
        var existing = standardized.deletingLastPathComponent()
        var missing: [String] = []
        while existing.path != "/" && !fm.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }

        var resolved = existing.resolvingSymlinksInPath()
        for component in missing { resolved.appendPathComponent(component) }
        resolved.appendPathComponent(lastComponent)
        return resolved.path
    }

    /// Length (in characters) of the longest entry in `roots` that is a path-boundary
    /// prefix of `path`, or -1 if none match. Boundary-safe: `/var` matches
    /// `/var/folders` but not `/variable`.
    private func longestPrefixLength(_ path: String, in roots: Set<String>) -> Int {
        var best = -1
        for entry in roots {
            let root = expandedPathValue(for: entry)
            if path == root || path.hasPrefix(root + "/") {
                if root.count > best { best = root.count }
            }
        }
        return best
    }

    private func isUnder(_ path: String, anyOf roots: Set<String>) -> Bool {
        longestPrefixLength(path, in: roots) >= 0
    }

    private func isPrivacyArtifact(_ path: String) -> Bool {
        let sharedFileList = expandedPathValue(for: "~/Library/Application Support/com.apple.sharedfilelist")
        if path == sharedFileList || path.hasPrefix(sharedFileList + "/") {
            return true
        }
        let safariDownloads = expandedPathValue(for: "~/Library/Safari/Downloads.plist")
        return path == safariDownloads
    }

    private func matchesPattern(_ filename: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*") {
            let suffix = String(pattern.dropFirst())
            return filename.hasSuffix(suffix)
        }
        return filename == pattern
    }

    private func isSymlinkSafe(_ url: URL) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return true
        }

        let targetURL: URL
        if target.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: target)
        } else {
            targetURL = url.deletingLastPathComponent().appendingPathComponent(target)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return targetURL.standardized.path.hasPrefix(home)
    }
}

private struct ValidationContext {
    enum Mode {
        case scan
        case cleanup
    }

    let mode: Mode
    let moduleID: String?
    let itemType: CleanupItem.ItemType?

    static func scan(moduleID: String?, itemType: CleanupItem.ItemType?) -> ValidationContext {
        ValidationContext(mode: .scan, moduleID: moduleID, itemType: itemType)
    }

    static func cleanup(moduleID: String?, itemType: CleanupItem.ItemType?) -> ValidationContext {
        ValidationContext(mode: .cleanup, moduleID: moduleID, itemType: itemType)
    }
}

private struct ModuleSafetyProfile {
    let allowsUserManagedScan: Bool
    let allowsUserManagedCleanup: Bool
    let allowsCloudScan: Bool
    let allowsCloudCleanup: Bool

    init(moduleID: String?) {
        switch moduleID {
        case "large-files":
            allowsUserManagedScan = true
            allowsUserManagedCleanup = false
            allowsCloudScan = false
            allowsCloudCleanup = false
        case "duplicates", "similar-photos":
            allowsUserManagedScan = true
            allowsUserManagedCleanup = true
            allowsCloudScan = false
            allowsCloudCleanup = false
        case "cloud-cleanup":
            allowsUserManagedScan = false
            allowsUserManagedCleanup = false
            allowsCloudScan = true
            allowsCloudCleanup = true
        default:
            allowsUserManagedScan = false
            allowsUserManagedCleanup = false
            allowsCloudScan = false
            allowsCloudCleanup = false
        }
    }
}

// MARK: - Validation Result

enum ValidationResult: Sendable {
    case safe
    case protected(reason: String)
    case sensitive(pattern: String)
    case symlink(reason: String)
    case unknown(reason: String)

    /// Default-deny: only `.safe` is safe. `.unknown` is treated as unsafe so that
    /// any path we do not positively recognize is left untouched.
    var isSafe: Bool {
        switch self {
        case .safe:
            return true
        case .protected, .sensitive, .symlink, .unknown:
            return false
        }
    }

    var reason: String? {
        switch self {
        case .safe:
            return nil
        case .protected(let reason), .symlink(let reason), .unknown(let reason):
            return reason
        case .sensitive(let pattern):
            return "Matches sensitive pattern: \(pattern)"
        }
    }
}

// MARK: - Protected Paths

struct ProtectedPaths {

    /// Paths that should NEVER be deleted
    static let neverDelete: Set<String> = [
        // System directories
        "/System",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin",
        "/Library",
        "/private",
        "/cores",
        "/etc",
        "/var",

        // User critical directories
        "~/Documents",
        "~/Desktop",
        "~/Pictures",
        "~/Movies",
        "~/Music",
        "~/Downloads",

        // Credentials and security
        "~/.ssh",
        "~/.gnupg",
        "~/.aws",
        "~/.kube",
        "~/.config",
        "~/.netrc",

        // App data (not caches)
        "~/Library/Preferences",
        "~/Library/Keychains",
        "~/Library/Mail",
        "~/Library/Messages",
        "~/Library/Calendars",
        "~/Library/Contacts",
        "~/Library/Reminders",
        "~/Library/Notes",
        "~/Library/Safari/Bookmarks.plist",
        "~/Library/Safari/History.db",
        "~/Library/Accounts",
        "~/Library/Cookies",

        // Cloud storage
        "~/Library/Mobile Documents",
        "~/Library/CloudStorage",
        "~/iCloud Drive",
        "~/Dropbox",
        "~/Google Drive",
        "~/OneDrive",

        // Development (sensitive)
        "~/.gitconfig",
        "~/.npmrc",
        "~/.pypirc",
    ]

    static let userManagedRoots: Set<String> = [
        "~/Documents",
        "~/Desktop",
        "~/Pictures",
        "~/Movies",
        "~/Music",
        "~/Downloads",
    ]

    static let cloudRoots: Set<String> = [
        "~/Library/Mobile Documents",
        "~/Library/CloudStorage",
        "~/iCloud Drive",
        "~/Dropbox",
        "~/Google Drive",
        "~/OneDrive",
    ]

    /// File patterns that indicate sensitive data
    static let sensitivePatterns: [String] = [
        // Keys and certificates
        "*.key",
        "*.pem",
        "*.p12",
        "*.pfx",
        "*.cer",
        "*.crt",
        "id_rsa",
        "id_ed25519",
        "id_ecdsa",
        "id_dsa",
        "*.ppk",

        // Credentials files
        "credentials.json",
        "secrets.json",
        "secrets.yaml",
        "secrets.yml",
        ".env",
        ".env.local",
        ".env.production",
        "*.keychain",
        "*.keychain-db",

        // Browser sensitive data
        "logins.json",
        "cookies.sqlite",
        "key4.db",
        "cert9.db",
        "signons.sqlite",

        // Database files (might contain sensitive data)
        "*.sqlite",
        "*.db",
        "*.sqlite3",
    ]

    /// Directories that are safe to clean (whitelist approach).
    /// Both `/var/folders` and `/private/var/folders` are listed because the
    /// system temp dir surfaces as `/var/folders/...` (a symlink) but may also be
    /// reported in its resolved `/private/var/folders/...` form.
    static let safeCacheRoots: Set<String> = [
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Library/Application Support/CrashReporter",
        "~/Library/Saved Application State",
        "/var/folders",
        "/private/var/folders",
    ]

    /// Package-manager cache roots that live OUTSIDE ~/Library/Caches and so are
    /// not covered by `safeCacheRoots`. Only the package-manager / dev-tools
    /// modules may clean these. None overlap a `neverDelete` root.
    static let packageManagerCacheRoots: Set<String> = [
        "~/.npm/_cacache",
        "~/.npm/_logs",
        "~/.yarn/cache",
        "~/Library/pnpm/store",
        "~/.bun/install/cache",
        "~/.local/pipx/.cache",
        "~/.cargo/registry/cache",
        "~/.cargo/git/checkouts",
        "~/go/pkg/mod/cache",
        "~/.composer/cache",
        "~/.gem/cache",
        "~/.gradle/caches",
        "~/.gradle/wrapper/dists",
        "~/.m2/repository",
        // mise download/metadata cache (XDG ~/.cache). NOT ~/.local/share/mise/installs,
        // which holds installed toolchains and must never be auto-cleaned.
        "~/.cache/mise",
    ]

    /// Developer + AI-tool cache/log roots surfaced by `CacheAnalyzer` and cleaned
    /// from the AI-Analysis view. They live outside ~/Library/Caches and are not
    /// covered by `safeDirectoryNames`. Only the `ai-analysis` cleanup may remove
    /// them; none overlap a `neverDelete` root. Kept in sync with the discovery
    /// roots in `CacheAnalyzer.runFastScan`.
    static let aiAnalysisCacheRoots: Set<String> = [
        "~/.npm/_cacache",
        "~/.npm/_npx",
        "~/.npm/_logs",
        "~/.bun/install/cache",
        "~/.yarn/cache",
        "~/.pnpm-store",
        "~/.cache/pip",
        "~/.cache/uv",
        "~/.cache/go-build",
        "~/.cargo/registry",
        "~/.cargo/git",
        "~/go/pkg/mod",
        "~/.gradle/caches",
        "~/.m2/repository",
        "~/.claude/debug",
        "~/.claude/paste-cache",
        "~/.claude/telemetry",
        "~/.claude/shell-snapshots",
        "~/.codex/log",
        "~/.codex/archived_sessions",
    ]

    /// Directory names that are generally safe to delete
    static let safeDirectoryNames: Set<String> = [
        "Cache",
        "Caches",
        "cache",
        "GPUCache",
        "ShaderCache",
        "Code Cache",
        "Service Worker",
        "node_modules",
        "__pycache__",
        ".pytest_cache",
        ".mypy_cache",
        "DerivedData",
        ".build",
        "target",
        "Pods",
        ".gradle",
        ".next",
        ".nuxt",
        "dist",
        "build",
        ".turbo",
        // NB: do NOT add "vendor/bundle" here — `NSString.pathComponents` never
        // yields a component containing "/", so it could never match, and the bare
        // "vendor"/"bundle" alternatives are unsafe (Go's vendored source, macOS
        // *.bundle packages). Ruby Bundler's vendor/bundle is cleaned with a
        // concrete resolved path by DevToolsModule instead.
    ]
}

// MARK: - Deletion Guard

struct DeletionGuard {
    /// Maximum total size for single operation (default 10GB)
    var maxTotalSize: Int64 = 10_737_418_240

    /// Require confirmation for operations over this size
    var confirmationThreshold: Int64 = 1_073_741_824  // 1GB

    /// Dry-run by default
    var dryRunDefault: Bool = true

    func preflightCheck(items: [CleanupItem]) -> PreflightResult {
        let totalSize = items.reduce(0) { $0 + $1.size }

        if totalSize > maxTotalSize {
            return .blocked(reason: "Total size exceeds maximum (\(ByteCountFormatter.string(fromByteCount: maxTotalSize, countStyle: .file)))")
        }

        if totalSize > confirmationThreshold {
            return .requiresConfirmation(size: totalSize)
        }

        return .allowed
    }
}

enum PreflightResult: Sendable, Equatable {
    case allowed
    case requiresConfirmation(size: Int64)
    case blocked(reason: String)
}

// MARK: - Path helpers

extension String {
    /// `~`-expanded copy of the path. Centralizes the `(self as NSString)`
    /// bridge-cast that several Core files repeat.
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
