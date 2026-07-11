import Foundation

/// Single source of truth for the MacSweep version string. Shared by the CLI
/// (`macsweep version`) and any caller that needs to report the running build.
/// Keep this in sync with `MARKETING_VERSION` in `MacSweep.xcodeproj`.
public enum MacSweepVersion {
    public static let current = "1.1.0"
}
