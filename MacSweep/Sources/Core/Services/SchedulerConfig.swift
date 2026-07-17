import Foundation

/// Shared persistent store for the weekly background-scan schedule, readable and
/// writable by BOTH the GUI app (`ScanScheduler`) and the `macsweep` CLI. The two
/// run as separate executables and cannot share `UserDefaults.standard`, so they
/// coordinate through an explicit shared suite domain
/// (`~/Library/Preferences/dev.macsweep.plist`), which any
/// non-sandboxed process on the machine can open by name. `dev.macsweep` is the
/// product's org-level namespace — the shared parent of the app's `dev.macsweep.app`
/// and the CLI's `dev.macsweep.cli` bundle ids — so it belongs to neither
/// executable's `UserDefaults.standard`; both name this suite explicitly.
///
/// `@unchecked Sendable`: the only stored property is a `UserDefaults`, which Apple
/// documents as thread-safe; the struct is otherwise immutable, so it is safe to
/// pass across the headless actor boundary.
public struct SchedulerConfig: @unchecked Sendable {
    public static let suiteName = "dev.macsweep"
    static let intervalDaysKey = "scanIntervalDays"
    static let nextScheduledScanKey = "nextScheduledScan"
    /// Key for the last-scan summary blob. Lives here so GUI (`LastScanStore`) and
    /// any future CLI consumer read/write the same suite plist, not separate domains.
    public static let lastScanKey = "lastScanSummary"
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
        // Treat any value below the minimum (incl. 0 / unset, or a hand-edited
        // plist) as "use the default"; only the upper bound needs clamping.
        guard stored >= Self.minIntervalDays else { return Self.defaultIntervalDays }
        return min(stored, Self.maxIntervalDays)
    }

    public var intervalSeconds: TimeInterval { TimeInterval(intervalDays) * 24 * 60 * 60 }

    /// Persists a new interval, clamping into range. Returns the value actually stored.
    @discardableResult
    public func setIntervalDays(_ days: Int) -> Int {
        let clamped = min(max(days, Self.minIntervalDays), Self.maxIntervalDays)
        defaults.set(clamped, forKey: Self.intervalDaysKey)
        return clamped
    }

    /// Persists a new interval and updates the next-run anchor to match the
    /// scheduler's enabled state. Disabled schedules retain the configured
    /// interval but never leave a stale next-run date behind.
    @discardableResult
    public func updateIntervalDays(
        _ days: Int,
        scheduleEnabled: Bool,
        now: Date = Date()
    ) -> Date? {
        setIntervalDays(days)

        let nextScan = scheduleEnabled
            ? now.addingTimeInterval(intervalSeconds)
            : nil
        setNextScheduledScan(nextScan)
        return nextScan
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
