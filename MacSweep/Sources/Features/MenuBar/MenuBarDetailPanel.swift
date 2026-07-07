import AppKit
import SwiftUI

/// Captures the NSWindow that hosts a SwiftUI view (used to find the menu-bar
/// dropdown's window so the detail panel can be anchored to it).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// A separate floating panel that hosts the menu-bar detail view, shown flush to
/// the LEFT of the menu-bar dropdown — CleanMyMac-style. Because it is its own
/// window, opening a detail never resizes or moves the main menu-bar panel.
@MainActor
final class MenuBarDetailPanel {
    static let shared = MenuBarDetailPanel()
    private var panel: NSPanel?

    /// Show `content` as a panel the same height as `anchor`, immediately to its left.
    func present(anchor: NSWindow, content: AnyView) {
        let width: CGFloat = 320
        let p = ensurePanel()
        p.level = anchor.level
        let a = anchor.frame
        p.contentView = NSHostingView(rootView: content.frame(width: width, height: a.height))
        p.setFrame(NSRect(x: a.minX - width, y: a.minY, width: width, height: a.height), display: true)
        p.orderFront(nil)
    }

    func dismiss() { panel?.orderOut(nil) }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
        return p
    }
}

/// The content rendered inside the side detail panel.
struct MenuBarDetailContent: View {
    let widget: WidgetType
    @ObservedObject var monitor: SystemMonitor
    let appState: AppState
    var onOpenFull: (Feature) -> Void
    /// One process monitor shared by the CPU and Memory detail views this panel
    /// hosts, so they don't each start a separate 5s `ps` loop (issue #103).
    @StateObject private var processMonitor = ProcessMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Button("Open Full View") { onOpenFull(feature) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            Group {
                switch widget {
                case .storage:
                    StorageDetailView(monitor: monitor).environmentObject(appState)
                case .memory:
                    MemoryDetailView(monitor: monitor, processMonitor: processMonitor)
                case .battery:
                    BatteryDetailView(monitor: monitor)
                case .cpu:
                    CPUDetailView(monitor: monitor, processMonitor: processMonitor)
                case .network:
                    NetworkDetailView(monitor: monitor)
                case .devices:
                    ConnectedDevicesDetailView(monitor: monitor, showsHeader: false)
                case .system:
                    SystemDetailView(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MacSweepCompanionSurface(radius: 14))
        .padding(8)
    }

    private var title: String {
        switch widget {
        case .storage: return "Macintosh HD"
        case .memory:  return "Memory"
        case .battery: return "Battery"
        case .cpu:     return "CPU"
        case .network: return monitor.networkUsage.ssid ?? "Wi-Fi"
        case .devices: return "Connected Devices"
        case .system:  return "System"
        }
    }

    private var feature: Feature {
        switch widget {
        case .storage:        return .spaceLens
        case .memory, .cpu:   return .optimization
        case .battery:        return .batteryMonitor
        case .network:        return .networkCleanup
        case .devices:        return .batteryMonitor
        case .system:         return .smartScan
        }
    }
}
