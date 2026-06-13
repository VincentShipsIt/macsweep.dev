import SwiftUI
import AppKit

// Headless visual-snapshot harness for the MacSweep GUI.
//
// Compiled IN-MODULE with the full app source set (minus MacSweepApp.swift, which
// owns the real @main) under `-DSWIFT_PACKAGE`, so it references ContentView,
// AppState, Feature and every feature view directly — no import needed.
//
// For each Feature it renders the *real* composed app shell (ContentView with
// `selectedFeature` preset) by hosting it in a fully OFF-SCREEN NSWindow (origin
// far in the negative quadrant, never ordered front) and capturing the hosting
// view's layer tree via `cacheDisplay(in:to:)`. This needs NO Screen Recording
// permission and never flashes a window on screen. It renders layout, text,
// icons, SF Symbols and shapes faithfully; pure-compositor effects (Liquid Glass
// refraction) are approximated, which is sufficient to verify structure — that
// the sidebar selection is the native highlight, not a broken custom pill, and
// that every feature screen lays out without crashing. If cacheDisplay yields an
// empty bitmap it falls back to SwiftUI's ImageRenderer so we always emit a PNG.
//
// Run via scripts/render-screenshots.sh. Output: scripts/screenshots/NN-feature.png
@main
struct SnapshotRenderer {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let outDir = snapshotOutputDir()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let shellSize = CGSize(width: 1000, height: 680)
        var index = 0
        var results: [(String, Bool, Int)] = []

        for feature in Feature.allCases {
            index += 1
            let slug = feature.slug
            let name = String(format: "%02d-%@", index, slug)
            let url = outDir.appendingPathComponent("\(name).png")

            let appState = AppState()
            appState.selectedFeature = feature
            let root = ContentView()
                .environmentObject(appState)
                .environment(\.colorScheme, .dark)
                .frame(width: shellSize.width, height: shellSize.height)

            let ok = renderToPNG(AnyView(root), size: shellSize, to: url)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            results.append((name, ok, bytes))
            FileHandle.standardError.write(Data("rendered \(name) ok=\(ok) bytes=\(bytes)\n".utf8))
        }

        // Summary line for the shell wrapper to parse.
        let good = results.filter { $0.1 && $0.2 > 5000 }.count
        FileHandle.standardError.write(Data("SNAPSHOT_SUMMARY rendered=\(results.count) usable=\(good) dir=\(outDir.path)\n".utf8))
        print("SNAPSHOT_DONE \(results.count) \(good) \(outDir.path)")
        exit(0)
    }

    // MARK: - Output dir

    @MainActor
    static func snapshotOutputDir() -> URL {
        // CWD is the repo root when invoked from the shell wrapper.
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent("scripts")
            .appendingPathComponent("screenshots")
    }

    // MARK: - Render

    @MainActor
    static func renderToPNG(_ view: AnyView, size: CGSize, to url: URL) -> Bool {
        // 1) Off-screen, no-permission, no-flash capture via cacheDisplay.
        if renderViaCacheDisplay(view, size: size, to: url), fileLooksUsable(url) {
            return true
        }
        // 2) Fallback: ImageRenderer (always produces a PNG).
        return renderWithImageRenderer(view, size: size, to: url)
    }

    @MainActor
    static func renderViaCacheDisplay(_ view: AnyView, size: CGSize, to url: URL) -> Bool {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.contentsScale = 2.0   // retina-resolution bitmap
        // Back-fill the hosting layer with the dark base colour. Native material
        // surfaces (the sidebar's NSVisualEffectView) cannot composite in an
        // off-screen cacheDisplay bitmap and would otherwise capture as white;
        // a dark fill makes those regions read as the real dark app would.
        hosting.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor

        // Host in a window placed far off any display and NEVER ordered front, so
        // SwiftUI performs a real layout pass (sidebar, lists, materials) without
        // anything appearing on screen and without Screen Recording permission.
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting

        // Drive layout and let async first paints settle.
        hosting.layoutSubtreeIfNeeded()
        pumpRunLoop(0.5)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            return false
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.close()

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    static func renderWithImageRenderer(_ view: AnyView, size: CGSize, to url: URL) -> Bool {
        let renderer = ImageRenderer(content:
            view.frame(width: size.width, height: size.height)
        )
        renderer.scale = 2.0
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    @MainActor
    static func pumpRunLoop(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    static func fileLooksUsable(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 5000
    }
}

// Compact filesystem-safe name per feature, derived from the stable enum case.
extension Feature {
    var slug: String {
        switch self {
        case .smartScan: return "smart-care"
        case .assistant: return "assistant"
        case .systemJunk: return "system-junk"
        case .mailAttachments: return "mail-attachments"
        case .trashBins: return "trash-bins"
        case .devTools: return "developer-tools"
        case .aiAnalysis: return "ai-analysis"
        case .networkCleanup: return "network-cleanup"
        case .cloudCleanup: return "cloud-cleanup"
        case .malwareRemoval: return "malware-removal"
        case .privacy: return "privacy"
        case .loginItems: return "login-items"
        case .optimization: return "optimization"
        case .batteryMonitor: return "battery-monitor"
        case .maintenance: return "maintenance"
        case .uninstaller: return "uninstaller"
        case .homebrewUpdater: return "homebrew-updater"
        case .updater: return "updater"
        case .extensions: return "extensions"
        case .spaceLens: return "space-lens"
        case .largeOldFiles: return "large-old-files"
        case .duplicateFiles: return "duplicate-files"
        case .similarPhotos: return "similar-photos"
        case .shredder: return "shredder"
        }
    }
}
