import Foundation

/// Module for cleaning package manager caches
struct PackageManagerModule: ScanModule {
    let id = "package-managers"
    let name = "Package Managers"
    let description = "Clean Homebrew, npm, pip, cargo, and other package manager caches"
    let icon = "shippingbox"

    /// Cache directories to surface, relative to the user's home. Each is gated by
    /// the shared `scanCacheDirectory` helper (exists + nonzero size). Adding a
    /// package manager is a one-line table entry now, not a copy-pasted block.
    private static let cacheTargets: [(path: String, name: String)] = [
        ("Library/Caches/Homebrew", "Homebrew Cache"),
        ("Library/Logs/Homebrew", "Homebrew Logs"),
        (".npm/_cacache", "npm Cache"),
        (".npm/_logs", "npm Logs"),
        ("Library/Caches/Yarn", "Yarn Cache"),
        (".yarn/cache", "Yarn Berry Cache"),
        ("Library/pnpm/store", "pnpm Store"),
        (".bun/install/cache", "Bun Cache"),
        ("Library/Caches/pip", "pip Cache"),
        (".local/pipx/.cache", "pipx Cache"),
        (".cargo/registry/cache", "Cargo Registry Cache"),
        (".cargo/git/checkouts", "Cargo Git Checkouts"),
        ("Library/Caches/go-build", "Go Build Cache"),
        ("go/pkg/mod/cache", "Go Module Cache"),
        (".composer/cache", "Composer Cache"),
        (".gem/cache", "RubyGems Cache"),
        ("Library/Caches/CocoaPods", "CocoaPods Cache"),
        ("Library/Caches/org.carthage.CarthageKit", "Carthage Cache"),
        (".gradle/caches", "Gradle Cache"),
        (".gradle/wrapper/dists", "Gradle Wrapper Distributions"),
        (".m2/repository", "Maven Repository"),
        // Only the re-fillable download/metadata cache (`~/.cache/mise`). The
        // installed toolchains under `~/.local/share/mise/installs` are deliberately
        // NOT scanned — deleting them removes working runtimes, not cache.
        (".cache/mise", "mise Cache"),
        ("Library/Caches/Mozilla.sccache", "sccache"),
        ("Library/Caches/deno", "Deno Cache"),
    ]

    func scan() async throws -> [CleanupItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var items: [CleanupItem] = []

        for target in Self.cacheTargets {
            if let item = await scanCacheDirectory(at: home.appending(path: target.path), moduleName: target.name) {
                items.append(item)
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(items, dryRun: dryRun) { item, _ in
            try CleanupFileRemover.recoverable(item.path)
        }
    }
}

// MARK: - Package Manager Info

struct PackageManagerInfo: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: String
    var cacheSize: Int64 = 0
    var cacheItems: [CleanupItem] = []

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    static let all: [PackageManagerInfo] = [
        PackageManagerInfo(id: "homebrew", name: "Homebrew", icon: "cup.and.saucer", color: "orange"),
        PackageManagerInfo(id: "npm", name: "npm", icon: "cube.box", color: "red"),
        PackageManagerInfo(id: "yarn", name: "Yarn", icon: "cube.box.fill", color: "blue"),
        PackageManagerInfo(id: "pnpm", name: "pnpm", icon: "shippingbox", color: "yellow"),
        PackageManagerInfo(id: "bun", name: "Bun", icon: "bolt", color: "pink"),
        PackageManagerInfo(id: "pip", name: "pip", icon: "cube", color: "blue"),
        PackageManagerInfo(id: "cargo", name: "Cargo", icon: "gearshape.2", color: "orange"),
        PackageManagerInfo(id: "go", name: "Go", icon: "figure.run", color: "cyan"),
        PackageManagerInfo(id: "composer", name: "Composer", icon: "music.note", color: "brown"),
        PackageManagerInfo(id: "gem", name: "RubyGems", icon: "diamond", color: "red"),
        PackageManagerInfo(id: "cocoapods", name: "CocoaPods", icon: "leaf", color: "red"),
        PackageManagerInfo(id: "carthage", name: "Carthage", icon: "cart", color: "blue"),
        PackageManagerInfo(id: "gradle", name: "Gradle", icon: "elephant", color: "green"),
        PackageManagerInfo(id: "maven", name: "Maven", icon: "m.circle", color: "red"),
        PackageManagerInfo(id: "mise", name: "mise", icon: "arrow.triangle.2.circlepath", color: "green"),
        PackageManagerInfo(id: "sccache", name: "sccache", icon: "bolt.horizontal", color: "orange"),
        PackageManagerInfo(id: "deno", name: "Deno", icon: "lizard", color: "gray"),
    ]
}
