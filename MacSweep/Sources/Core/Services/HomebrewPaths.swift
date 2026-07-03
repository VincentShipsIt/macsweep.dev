import Foundation

/// Single source of truth for locating a Homebrew installation across the two
/// standard prefixes — Apple Silicon (`/opt/homebrew`) and Intel (`/usr/local`).
///
/// Replaces five independent, subtly inconsistent resolvers that had drifted:
/// some probed the `brew` binary, some the prefix, and one (`SystemMonitor`'s
/// `osx-cpu-temp` lookup) only ever checked the Apple-Silicon path, so it silently
/// no-op'd on Intel.
///
/// The resolution logic is split into pure `resolve*` cores that take an
/// existence predicate (so they're deterministically unit-testable with a stubbed
/// filesystem) and thin public members bound to the real `FileManager`.
enum HomebrewPaths {
    /// Candidate prefixes in probe order: Apple Silicon first, then Intel.
    static let prefixCandidates = ["/opt/homebrew", "/usr/local"]

    // MARK: - Real-filesystem API

    /// The active prefix — the first candidate whose `bin/brew` exists — or nil
    /// when Homebrew is not installed.
    static var prefix: String? { resolvePrefix(exists: realFileExists) }

    /// Absolute path to the `brew` binary, or nil when Homebrew is not installed.
    static var brewPath: String? { resolveBrewPath(exists: realFileExists) }

    /// Whether a Homebrew installation is present.
    static var isInstalled: Bool { prefix != nil }

    /// Resolve a Homebrew-installed tool (e.g. `osx-cpu-temp`, `docker`) to its
    /// absolute path, checking `bin` then `sbin` under each prefix. Returns the
    /// first candidate that exists, or nil.
    static func toolPath(_ name: String) -> String? {
        resolveToolPath(name, exists: realFileExists)
    }

    // MARK: - Pure cores (testable with a stubbed existence predicate)

    static func resolvePrefix(exists: (String) -> Bool) -> String? {
        prefixCandidates.first { exists($0 + "/bin/brew") }
    }

    static func resolveBrewPath(exists: (String) -> Bool) -> String? {
        resolvePrefix(exists: exists).map { $0 + "/bin/brew" }
    }

    static func resolveToolPath(_ name: String, exists: (String) -> Bool) -> String? {
        for prefix in prefixCandidates {
            for directory in ["bin", "sbin"] {
                let candidate = "\(prefix)/\(directory)/\(name)"
                if exists(candidate) { return candidate }
            }
        }
        return nil
    }

    private static let realFileExists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }
}
