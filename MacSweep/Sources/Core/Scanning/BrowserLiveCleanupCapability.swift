import Foundation

/// Product capability for an already-running normal profile, without relaunch or prior debugging setup.
/// Isolated CDP support is evidence about the protocol, not authority to attach to real login sessions.
enum BrowserLiveCleanupCapability {
    static let braveDetail =
        "Live Brave worker cleanup is unavailable for normal profiles: MacSweep cannot "
        + "attach a browser-owned worker-registration/cache-only operation without prior debugging setup. "
        + "Brave stays open and selected targets are skipped. Cookies, Login Data and Local Storage are retained. "
        + "For offline cleanup, quit Brave yourself and rescan."

    static func retentionReason(browserID: String, running: Bool) -> String? {
        browserID == "browser-brave" && running ? braveDetail : nil
    }
}
