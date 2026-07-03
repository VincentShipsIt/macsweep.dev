import Foundation

/// A UUID-scoped temporary directory: created on init, removed on deinit.
///
/// XCTest-agnostic replacement for the init/deinit pair previously copied
/// across test suites. swift-testing creates a fresh suite instance per @Test,
/// so holding one of these as a stored property gives per-test setUp/tearDown,
/// and the UUID scope keeps parallel test execution collision-free.
///
/// `~Copyable` so the directory has exactly one owner — its removal is tied to
/// that single value's lifetime, like the hand-written deinit it replaces.
struct TempTestDirectory: ~Copyable {
    let url: URL

    init(prefix: String = "MacSweepTests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        // No fileExists gate: removeItem's not-found error is already swallowed
        // by try?, and racing the check against removal buys nothing.
        try? FileManager.default.removeItem(at: url)
    }

    /// Convenience passthrough for building fixture paths.
    func appendingPathComponent(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }
}
