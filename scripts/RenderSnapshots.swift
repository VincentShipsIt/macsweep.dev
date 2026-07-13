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

            // Keep missing-permission recovery deterministic on the three
            // protected-data feature landings even when the host has granted
            // Full Disk Access to the harness. Smart Care gets a dedicated
            // direct-view variant below because its live monitors make the
            // composed navigation snapshot timing-sensitive.
            let needsMissingAccess = feature == .systemJunk
                || feature == .mailAttachments
                || feature == .privacy
            let appState = AppState(initialFullDiskAccess: !needsMissingAccess)
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

        // Data-state variants: the loop above captures every feature's empty launch
        // state; these extra passes capture the populated and error layouts of the
        // three deletion-bearing flows, which only render once a scan has data.
        for (slug, view) in dataStateVariants(size: shellSize) {
            index += 1
            let name = String(format: "%02d-%@", index, slug)
            let url = outDir.appendingPathComponent("\(name).png")
            let ok = renderToPNG(view, size: shellSize, to: url)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            results.append((name, ok, bytes))
            FileHandle.standardError.write(Data("rendered \(name) ok=\(ok) bytes=\(bytes)\n".utf8))
        }

        for (slug, view, size) in onboardingVariants() {
            index += 1
            let name = String(format: "%02d-%@", index, slug)
            let url = outDir.appendingPathComponent("\(name).png")
            let ok = renderToPNG(view, size: size, to: url)
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

    // MARK: - Data-state variants

    /// Builds the populated / error layouts for the three deletion-bearing flows.
    /// SystemCleanup reads its rows straight off `AppState`; LargeFiles and the
    /// Uninstaller hold local `@State`, so they take the snapshot-injection
    /// initializers added on each view. Every view still renders through the real
    /// composed body — only the seed data is synthetic.
    @MainActor
    static func dataStateVariants(size: CGSize) -> [(String, AnyView)] {
        func wrap<V: View>(_ view: V, appState: AppState) -> AnyView {
            AnyView(
                view
                    .environmentObject(appState)
                    .environment(\.colorScheme, .dark)
                    .frame(width: size.width, height: size.height)
            )
        }

        let cleanupState = AppState()
        let cleanupItems = sampleCleanupItems()
        cleanupState.scanResults = cleanupItems
        cleanupState.selectedItems = Set(cleanupItems.prefix(3).map(\.id))

        let largeItems = sampleLargeItems()
        let largeSelection = Set(largeItems.prefix(2).map(\.id))

        let apps = sampleApps()
        let orphans = sampleOrphans()

        return [
            ("smart-care-missing-full-disk-access", wrap(
                DashboardView(),
                appState: AppState(initialFullDiskAccess: false)
            )),
            ("system-junk-results", wrap(SystemCleanupView(), appState: cleanupState)),
            ("large-old-files-results", wrap(
                LargeFilesView(snapshotItems: largeItems, snapshotSelection: largeSelection),
                appState: AppState()
            )),
            ("large-old-files-error", wrap(
                LargeFilesView(
                    snapshotItems: [],
                    snapshotError: "Couldn't scan for large files: permission denied"
                ),
                appState: AppState()
            )),
            ("uninstaller-results", wrap(
                AppUninstallerView(
                    snapshotApps: apps,
                    snapshotSelectedApp: apps.first,
                    snapshotOrphans: orphans
                ),
                appState: AppState()
            )),
            ("uninstaller-error", wrap(
                AppUninstallerView(
                    snapshotApps: [],
                    snapshotError: "Couldn't uninstall Google Chrome: Administrator privileges required"
                ),
                appState: AppState()
            )),
        ]
    }

    @MainActor
    static func onboardingVariants() -> [(String, AnyView, CGSize)] {
        let size = CGSize(width: 650, height: 550)
        let root = OnboardingView(
            isPresented: .constant(true),
            initialPage: 2,
            initialFullDiskAccess: false
        )
        .environment(\.colorScheme, .dark)
        .frame(width: size.width, height: size.height)

        return [("onboarding-full-disk-access", AnyView(root), size)]
    }

    // MARK: - Sample data

    /// Fixed reference instant so successive renders produce stable "modified N
    /// days ago" labels; this binary is free to call `Date()` but a frozen base
    /// keeps the snapshots reproducible across runs.
    private static let sampleBaseDate = Date(timeIntervalSince1970: 1_749_000_000)

    private static func daysAgo(_ days: Double) -> Date {
        sampleBaseDate.addingTimeInterval(-days * 86_400)
    }

    /// System-junk rows for the SystemCleanup results layout: a realistic spread
    /// of cache/log directories across browsers, dev tooling and the OS.
    @MainActor
    static func sampleCleanupItems() -> [CleanupItem] {
        func item(_ name: String, _ size: Int64, _ moduleName: String, _ age: Double) -> CleanupItem {
            CleanupItem(
                id: UUID(),
                path: URL(fileURLWithPath: "/Users/you/Library/Caches/\(name)"),
                size: size,
                type: .directory,
                module: "system-cleanup",
                moduleName: moduleName,
                lastModified: daysAgo(age)
            )
        }
        return [
            item("com.apple.Safari", 1_240_000_000, "Browser Cache", 2),
            item("Google/Chrome/Default", 4_100_000_000, "Browser Cache", 1),
            item("com.apple.dt.Xcode", 2_600_000_000, "Developer Cache", 5),
            item("Homebrew/downloads", 980_000_000, "Developer Cache", 9),
            item("com.apple.appstore", 312_000_000, "System Cache", 14),
            item("CrashReporter/diagnostics", 94_000_000, "System Logs", 21),
        ]
    }

    /// Large-file rows for the LargeFiles results layout. The `moduleName` of each
    /// row drives the category colour/icon in the view, so the sample spans the
    /// distinct categories the view knows about. Every size is >= the 100 MB floor
    /// the view filters on so all rows survive into `filteredItems`.
    @MainActor
    static func sampleLargeItems() -> [CleanupItem] {
        func item(_ path: String, _ size: Int64, _ type: CleanupItem.ItemType, _ moduleName: String, _ age: Double) -> CleanupItem {
            CleanupItem(
                id: UUID(),
                path: URL(fileURLWithPath: path),
                size: size,
                type: type,
                module: "large-files",
                moduleName: moduleName,
                lastModified: daysAgo(age)
            )
        }
        return [
            item("/Users/you/Movies/wwdc-keynote-4k.mov", 6_800_000_000, .file, "Video", 40),
            item("/Users/you/Downloads/Xcode_16.xip", 7_200_000_000, .file, "Archive", 120),
            item("/Users/you/Downloads/Sonoma-installer.dmg", 13_400_000_000, .file, "Disk Image", 200),
            item("/Users/you/Projects/old-monorepo", 3_900_000_000, .directory, "Folder", 95),
            item("/Users/you/Documents/architecture-review.pdf", 142_000_000, .file, "Document", 310),
            item("/Users/you/Music/Logic/session-stems.logicx", 2_100_000_000, .directory, "Audio", 58),
        ]
    }

    /// Three installed apps with their per-app leftovers for the Uninstaller
    /// results layout. `icon: nil` is handled by AppListRow (falls back to an SF
    /// Symbol), so no real bundle on disk is needed.
    @MainActor
    static func sampleApps() -> [InstalledApp] {
        func leftover(_ path: String, _ size: Int64, _ type: AppLeftover.LeftoverType) -> AppLeftover {
            AppLeftover(id: UUID(), path: URL(fileURLWithPath: path), size: size, type: type)
        }
        let chrome = InstalledApp(
            id: "com.google.Chrome",
            name: "Google Chrome",
            bundlePath: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            version: "126.0.6478.62",
            bundleSize: 1_480_000_000,
            icon: nil,
            lastUsed: daysAgo(1),
            leftovers: [
                leftover("~/Library/Application Support/Google/Chrome", 2_300_000_000, .applicationSupport),
                leftover("~/Library/Caches/Google/Chrome", 540_000_000, .caches),
                leftover("~/Library/Preferences/com.google.Chrome.plist", 84_000, .preferences),
            ]
        )
        let figma = InstalledApp(
            id: "com.figma.Desktop",
            name: "Figma",
            bundlePath: URL(fileURLWithPath: "/Applications/Figma.app"),
            version: "124.6.4",
            bundleSize: 720_000_000,
            icon: nil,
            lastUsed: daysAgo(6),
            leftovers: [
                leftover("~/Library/Application Support/Figma", 410_000_000, .applicationSupport),
                leftover("~/Library/Logs/Figma", 26_000_000, .logs),
            ]
        )
        let slack = InstalledApp(
            id: "com.tinyspeck.slackmacgap",
            name: "Slack",
            bundlePath: URL(fileURLWithPath: "/Applications/Slack.app"),
            version: "4.38.121",
            bundleSize: 310_000_000,
            icon: nil,
            lastUsed: daysAgo(30),
            leftovers: [
                leftover("~/Library/Containers/com.tinyspeck.slackmacgap", 880_000_000, .containers),
                leftover("~/Library/Saved Application State/com.tinyspeck.slackmacgap.savedState", 12_000_000, .savedState),
            ]
        )
        return [chrome, figma, slack]
    }

    /// Orphaned leftovers (apps no longer installed) for the Uninstaller's
    /// orphan-cleanup affordance.
    @MainActor
    static func sampleOrphans() -> [AppLeftover] {
        [
            AppLeftover(id: UUID(), path: URL(fileURLWithPath: "~/Library/Application Support/Spotify"), size: 1_100_000_000, type: .applicationSupport),
            AppLeftover(id: UUID(), path: URL(fileURLWithPath: "~/Library/Caches/com.zoom.xos"), size: 430_000_000, type: .caches),
            AppLeftover(id: UUID(), path: URL(fileURLWithPath: "~/Library/Logs/Docker Desktop"), size: 58_000_000, type: .logs),
        ]
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
        case .share: return "share"
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
