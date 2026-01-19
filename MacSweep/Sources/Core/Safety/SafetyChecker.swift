import Foundation

/// Safety validation to prevent accidental deletion of critical files
struct SafetyChecker: Sendable {

    // MARK: - Validation

    func validate(_ url: URL) -> ValidationResult {
        let path = url.path
        let expandedPath = (path as NSString).expandingTildeInPath

        // Check never-delete paths
        for protectedPath in ProtectedPaths.neverDelete {
            let expanded = (protectedPath as NSString).expandingTildeInPath
            if expandedPath.hasPrefix(expanded) || expandedPath == expanded {
                return .protected(reason: "System or user critical path")
            }
        }

        // Check sensitive file patterns
        let filename = url.lastPathComponent.lowercased()
        for pattern in ProtectedPaths.sensitivePatterns {
            if matchesPattern(filename, pattern: pattern) {
                return .sensitive(pattern: pattern)
            }
        }

        // Check if it's a symlink pointing outside home
        if let _ = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            if !isSymlinkSafe(url) {
                return .symlink(reason: "Points outside home directory")
            }
        }

        // Check if within safe cache roots
        for safeRoot in ProtectedPaths.safeCacheRoots {
            let expanded = (safeRoot as NSString).expandingTildeInPath
            if expandedPath.hasPrefix(expanded) {
                return .safe
            }
        }

        // Check if within safe directory names
        let components = url.pathComponents
        for safeName in ProtectedPaths.safeDirectoryNames {
            if components.contains(safeName) {
                return .safe
            }
        }

        // Default: not explicitly safe or protected
        return .unknown(reason: "Path not in known safe or protected lists")
    }

    func validateBatch(_ urls: [URL]) -> [URL: ValidationResult] {
        var results: [URL: ValidationResult] = [:]
        for url in urls {
            results[url] = validate(url)
        }
        return results
    }

    // MARK: - Helpers

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
        return targetURL.path.hasPrefix(home)
    }
}

// MARK: - Validation Result

enum ValidationResult: Sendable {
    case safe
    case protected(reason: String)
    case sensitive(pattern: String)
    case symlink(reason: String)
    case unknown(reason: String)

    var isSafe: Bool {
        switch self {
        case .safe, .unknown:
            return true
        case .protected, .sensitive, .symlink:
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

    /// Directories that are safe to clean (whitelist approach)
    static let safeCacheRoots: Set<String> = [
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Library/Application Support/CrashReporter",
        "~/Library/Saved Application State",
        "/private/var/folders",
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
        "vendor/bundle",
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

enum PreflightResult {
    case allowed
    case requiresConfirmation(size: Int64)
    case blocked(reason: String)
}
