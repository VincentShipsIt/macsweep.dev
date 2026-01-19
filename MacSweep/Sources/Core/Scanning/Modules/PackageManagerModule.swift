import Foundation

/// Module for cleaning package manager caches
struct PackageManagerModule: ScanModule {
    let id = "package-managers"
    let name = "Package Managers"
    let description = "Clean Homebrew, npm, pip, cargo, and other package manager caches"
    let icon = "shippingbox"

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Scan all package managers
        items.append(contentsOf: await scanHomebrew())
        items.append(contentsOf: await scanNpm())
        items.append(contentsOf: await scanYarn())
        items.append(contentsOf: await scanPnpm())
        items.append(contentsOf: await scanBun())
        items.append(contentsOf: await scanPip())
        items.append(contentsOf: await scanCargo())
        items.append(contentsOf: await scanGo())
        items.append(contentsOf: await scanComposer())
        items.append(contentsOf: await scanGem())
        items.append(contentsOf: await scanCocoaPods())
        items.append(contentsOf: await scanCarthage())
        items.append(contentsOf: await scanGradle())
        items.append(contentsOf: await scanMaven())

        return items.sorted { $0.size > $1.size }
    }

    // MARK: - Homebrew

    private func scanHomebrew() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Homebrew cache
        let brewCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Homebrew")

        if FileManager.default.fileExists(atPath: brewCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: brewCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: brewCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Homebrew Cache"
                ))
            }
        }

        // Homebrew downloads
        let brewDownloads = URL(fileURLWithPath: "/usr/local/Homebrew/Library/Taps")
        // Old versions in Cellar - would need special handling

        // Homebrew logs
        let brewLogs = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Homebrew")

        if FileManager.default.fileExists(atPath: brewLogs.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: brewLogs)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: brewLogs,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Homebrew Logs"
                ))
            }
        }

        return items
    }

    // MARK: - npm

    private func scanNpm() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let npmCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".npm/_cacache")

        if FileManager.default.fileExists(atPath: npmCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: npmCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: npmCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "npm Cache"
                ))
            }
        }

        // npm logs
        let npmLogs = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".npm/_logs")

        if FileManager.default.fileExists(atPath: npmLogs.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: npmLogs)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: npmLogs,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "npm Logs"
                ))
            }
        }

        return items
    }

    // MARK: - Yarn

    private func scanYarn() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        // Yarn 1.x cache
        let yarnCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Yarn")

        if FileManager.default.fileExists(atPath: yarnCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: yarnCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: yarnCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Yarn Cache"
                ))
            }
        }

        // Yarn Berry (2+) cache
        let yarnBerryCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".yarn/cache")

        if FileManager.default.fileExists(atPath: yarnBerryCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: yarnBerryCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: yarnBerryCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Yarn Berry Cache"
                ))
            }
        }

        return items
    }

    // MARK: - pnpm

    private func scanPnpm() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let pnpmStore = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/pnpm/store")

        if FileManager.default.fileExists(atPath: pnpmStore.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: pnpmStore)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: pnpmStore,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "pnpm Store"
                ))
            }
        }

        return items
    }

    // MARK: - Bun

    private func scanBun() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let bunCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".bun/install/cache")

        if FileManager.default.fileExists(atPath: bunCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: bunCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: bunCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Bun Cache"
                ))
            }
        }

        return items
    }

    // MARK: - pip

    private func scanPip() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let pipCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/pip")

        if FileManager.default.fileExists(atPath: pipCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: pipCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: pipCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "pip Cache"
                ))
            }
        }

        // pipx
        let pipxCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/pipx/.cache")

        if FileManager.default.fileExists(atPath: pipxCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: pipxCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: pipxCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "pipx Cache"
                ))
            }
        }

        return items
    }

    // MARK: - Cargo (Rust)

    private func scanCargo() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let cargoRegistry = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cargo/registry/cache")

        if FileManager.default.fileExists(atPath: cargoRegistry.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: cargoRegistry)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: cargoRegistry,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Cargo Registry Cache"
                ))
            }
        }

        // Cargo git checkouts
        let cargoGit = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".cargo/git/checkouts")

        if FileManager.default.fileExists(atPath: cargoGit.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: cargoGit)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: cargoGit,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Cargo Git Checkouts"
                ))
            }
        }

        return items
    }

    // MARK: - Go

    private func scanGo() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let goCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/go-build")

        if FileManager.default.fileExists(atPath: goCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: goCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: goCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Go Build Cache"
                ))
            }
        }

        // Go mod cache
        let goModCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "go/pkg/mod/cache")

        if FileManager.default.fileExists(atPath: goModCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: goModCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: goModCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Go Module Cache"
                ))
            }
        }

        return items
    }

    // MARK: - Composer (PHP)

    private func scanComposer() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let composerCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".composer/cache")

        if FileManager.default.fileExists(atPath: composerCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: composerCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: composerCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Composer Cache"
                ))
            }
        }

        return items
    }

    // MARK: - Gem (Ruby)

    private func scanGem() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let gemCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".gem/cache")

        if FileManager.default.fileExists(atPath: gemCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: gemCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: gemCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "RubyGems Cache"
                ))
            }
        }

        return items
    }

    // MARK: - CocoaPods

    private func scanCocoaPods() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let podsCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/CocoaPods")

        if FileManager.default.fileExists(atPath: podsCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: podsCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: podsCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "CocoaPods Cache"
                ))
            }
        }

        return items
    }

    // MARK: - Carthage

    private func scanCarthage() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let carthageCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/org.carthage.CarthageKit")

        if FileManager.default.fileExists(atPath: carthageCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: carthageCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: carthageCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Carthage Cache"
                ))
            }
        }

        return items
    }

    // MARK: - Gradle

    private func scanGradle() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let gradleCache = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".gradle/caches")

        if FileManager.default.fileExists(atPath: gradleCache.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: gradleCache)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: gradleCache,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Gradle Cache"
                ))
            }
        }

        // Gradle wrapper distributions
        let gradleWrapper = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".gradle/wrapper/dists")

        if FileManager.default.fileExists(atPath: gradleWrapper.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: gradleWrapper)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: gradleWrapper,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Gradle Wrapper Distributions"
                ))
            }
        }

        return items
    }

    // MARK: - Maven

    private func scanMaven() async -> [CleanupItem] {
        var items: [CleanupItem] = []

        let mavenRepo = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".m2/repository")

        if FileManager.default.fileExists(atPath: mavenRepo.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: mavenRepo)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: mavenRepo,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Maven Repository"
                ))
            }
        }

        return items
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
            } else {
                do {
                    try FileManager.default.removeItem(at: item.path)
                    processed += 1
                    freed += item.size
                } catch {
                    errors.append(CleanupError(
                        path: item.path,
                        message: error.localizedDescription,
                        underlyingError: error
                    ))
                }
            }
        }

        return CleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
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
    ]
}
