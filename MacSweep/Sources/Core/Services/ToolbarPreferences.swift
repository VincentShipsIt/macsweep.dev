/// Stable `UserDefaults` keys used by the app's menu-bar surfaces.
///
/// These models live in MacSweepCore so their persisted contract and display
/// metadata are covered by the SwiftPM test suite instead of being hidden in the
/// GUI-only `AppState` file.
enum MenuBarPreferences {
    /// Defaults key backing Settings → General → "Show menu bar icon";
    /// consumed by the `MenuBarExtra(isInserted:)` binding in `MacSweepApp`.
    static let iconVisibleKey = "showMenuBarIcon"
}

enum CompanionToolbarPreferences {
    static let storageCardVisible = "companion.toolbar.card.storage.visible"
    static let memoryCardVisible = "companion.toolbar.card.memory.visible"
    static let batteryCardVisible = "companion.toolbar.card.battery.visible"
    static let cpuCardVisible = "companion.toolbar.card.cpu.visible"
    static let networkCardVisible = "companion.toolbar.card.network.visible"
    static let devicesCardVisible = "companion.toolbar.card.devices.visible"
    static let smartCareCardVisible = "companion.toolbar.card.smartCare.visible"
}

enum CompanionToolbarCard: String, CaseIterable, Identifiable {
    case storage
    case memory
    case battery
    case cpu
    case network
    case devices
    case smartCare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storage: return "Macintosh HD"
        case .memory: return "Memory"
        case .battery: return "Battery"
        case .cpu: return "CPU"
        case .network: return "Wi-Fi"
        case .devices: return "Devices"
        case .smartCare: return "Smart Care"
        }
    }

    var icon: String {
        switch self {
        case .storage: return "internaldrive"
        case .memory: return "memorychip"
        case .battery: return "battery.100"
        case .cpu: return "cpu"
        case .network: return "wifi"
        case .devices: return "antenna.radiowaves.left.and.right"
        case .smartCare: return "magnifyingglass"
        }
    }

    var visibilityKey: String {
        switch self {
        case .storage: return CompanionToolbarPreferences.storageCardVisible
        case .memory: return CompanionToolbarPreferences.memoryCardVisible
        case .battery: return CompanionToolbarPreferences.batteryCardVisible
        case .cpu: return CompanionToolbarPreferences.cpuCardVisible
        case .network: return CompanionToolbarPreferences.networkCardVisible
        case .devices: return CompanionToolbarPreferences.devicesCardVisible
        case .smartCare: return CompanionToolbarPreferences.smartCareCardVisible
        }
    }
}
