import Foundation

/// Shared persistent store for the weekly background-scan schedule, readable and
/// writable by BOTH the GUI app (`ScanScheduler`) and the `macsweep` CLI. The two
/// run as separate executables and cannot share `UserDefaults.standard`, so they
/// coordinate through an explicit suite domain
/// (`~/Library/Preferences/com.vincentshipsit.macsweep.plist`), which any
/// non-sandboxed process on the machine can open by name. The GUI app's bundle id
/// is itself `com.vincentshipsit.macsweep`, so its `UserDefaults.standard` resolves
/// to the same plist — the CLI just names the suite explicitly.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which Apple
/// documents as thread-safe; the struct is otherwise immutable, so it is safe to
/// pass across the headless actor boundary.
public struct SchedulerConfig: @unchecked Sendable {
    public static let suiteName = "com.vincentshipsit.macsweep"
    static let intervalDaysKey = "scanIntervalDays"
    static let nextScheduledScanKey = "nextScheduledScan"
    public static let defaultIntervalDays = 7
    public static let minIntervalDays = 1
    public static let maxIntervalDays = 365

    private let defaults: UserDefaults

    /// - Parameter defaults: injection seam for tests. In production this is `nil`,
    ///   resolving to the shared suite domain (falling back to `.standard` only if
    ///   the suite cannot be opened, which never happens for a valid bundle id).
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    /// Configured interval in whole days, clamped to `[min, max]`. Falls back to the
    /// default when unset or non-positive.
    public var intervalDays: Int {
        let stored = defaults.integer(forKey: Self.intervalDaysKey)
        guard stored > 0 else { return Self.defaultIntervalDays }
        return min(max(stored, Self.minIntervalDays), Self.maxIntervalDays)
    }

    public var intervalSeconds: TimeInterval { TimeInterval(intervalDays) * 24 * 60 * 60 }

    /// Persists a new interval, clamping into range. Returns the value actually stored.
    @discardableResult
    public func setIntervalDays(_ days: Int) -> Int {
        let clamped = min(max(days, Self.minIntervalDays), Self.maxIntervalDays)
        defaults.set(clamped, forKey: Self.intervalDaysKey)
        return clamped
    }

    public var nextScheduledScan: Date? {
        defaults.object(forKey: Self.nextScheduledScanKey) as? Date
    }

    public func setNextScheduledScan(_ date: Date?) {
        if let date {
            defaults.set(date, forKey: Self.nextScheduledScanKey)
        } else {
            defaults.removeObject(forKey: Self.nextScheduledScanKey)
        }
    }
}
