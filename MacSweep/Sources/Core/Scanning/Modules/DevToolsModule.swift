import Foundation

struct DevToolsModule: ScanModule {
    static let defaultMaxDepth = 6
    let id = "dev-tools"
    let name = "Developer Tools"
    let description = "Review generated build artifacts and developer caches"
    let icon = "wrench.and.screwdriver"
    var searchPaths: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var maxDepth: Int = Self.defaultMaxDepth
    var minimumDirectorySize: Int64 = 1_048_576
    var includesSystemCaches = true
    var safety = DevArtifactSafety()
    var remove: @Sendable (URL) throws -> Void = { try CleanupFileRemover.recoverable($0, module: "dev-tools") }

    private struct Candidate: Sendable {
        let url: URL
        let name: String
        let type: CleanupItem.ItemType
    }

    func scan() async throws -> [CleanupItem] {
        let processes = try await safety.processSnapshot()
        let candidates = try await DevArtifactIO.run {
            let roots = searchPaths.flatMap { DeveloperScanRoots.paths(in: $0, homeDirectory: homeDirectory) }
            let specialRoots = Set(GitArtifactScanner.worktreeRoots(in: homeDirectory).map(\.path))
            var found: [Candidate] = []
            var inspected = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            for root in roots {
                guard
                    let enumerator = ScanFileSystem.enumerator(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: [.skipsPackageDescendants]
                    )
                else { continue }
                while let url = enumerator.nextObject() as? URL {
                    inspected += 1
                    guard inspected <= 500_000, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw DevArtifactSafetyError(
                            "Developer artifact discovery exceeded its safety limit. Narrow the scan roots.")
                    }
                    let depth = enumerator.level
                    if depth > maxDepth { enumerator.skipDescendants(); continue }
                    let name = url.lastPathComponent
                    let pattern = DevArtifactPattern.allPatterns.first { $0.matches(url) }
                    if [".git", ".svn", ".hg", "Library", ".Trash"].contains(name)
                        || name.hasPrefix(".") && pattern == nil
                            && !(depth == 1 && specialRoots.contains(root.standardizedFileURL.path))
                    {
                        enumerator.skipDescendants()
                        continue
                    }
                    if let pattern {
                        found.append(
                            Candidate(
                                url: url, name: pattern.name,
                                type: pattern.fileExtension == nil ? .directory : .file))
                        enumerator.skipDescendants()
                    } else if ["node_modules", "vendor", "Pods", "target", "build", "dist"].contains(name) {
                        enumerator.skipDescendants()
                    }
                }
            }
            return found
        }
        var items: [CleanupItem] = []
        var seen = Set<String>()
        var targets = candidates
        if includesSystemCaches {
            targets += DevArtifactSafety.fixedTargets(in: safety.libraryDirectory).map {
                Candidate(url: $0.path, name: $0.name, type: .directory)
            }
        }
        for target in targets {
            let (url, title, type) = (target.url, target.name, target.type)
            try Task.checkCancellation()
            guard ScanFileSystem.exists(atPath: url.path),
                seen.insert(url.standardizedFileURL.path).inserted
            else { continue }
            let receipt = await safety.assess(url, processes: processes)
            let size: Int64
            do {
                size =
                    type == .file
                    ? Int64(try url.scanResourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
                    : try await DiskAnalyzer.directorySize(at: url)
            } catch { ScanDiagnostics.current?.record(error, at: url); continue }
            guard size > (type == .file ? 0 : minimumDirectorySize) else { continue }
            let date = try? url.scanResourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let item = CleanupItem(
                id: UUID(), path: url, size: size, type: type, module: id, moduleName: title,
                lastModified: date, contentModificationDate: date,
                cleanupReviewReason: receipt.isEligible ? nil : receipt.reason,
                devArtifactReceipt: receipt)
            if SafetyChecker().validateForScan(item, moduleID: id).isSafe { items.append(item) }
        }
        return items.sorted { $0.size > $1.size }
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        await cleanItems(
            items, dryRun: dryRun, errorMessage: { $0.localizedDescription },
            remove: { item, checker in
                guard let scanned = item.devArtifactReceipt, let expected = scanned.identity, scanned.isEligible else {
                    throw DevArtifactSafetyError("A verified artifact scan is required before cleanup.")
                }
                let fresh = await safety.assess(item.path, expected: expected, checker: checker)
                guard fresh.isEligible else { throw DevArtifactSafetyError(fresh.reason) }
                guard fresh.content == scanned.content else {
                    throw DevArtifactSafetyError("Artifact contents changed since scanning. Rescan before cleanup.")
                }
                try await DevArtifactIO.run {
                    // Keep the final content/identity checks and Trash on one utility task.
                    guard try DevArtifactIdentity.read(item.path) == expected,
                        try DevArtifactContent.validateTree(
                            item.path,
                            genericOutput: ["dist", "build"].contains(item.path.lastPathComponent),
                            checker: checker) == fresh.content,
                        checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe
                    else {
                        throw DevArtifactSafetyError("Target changed immediately before cleanup and was retained.")
                    }
                    try fresh.gitEvidence?.validate()
                    try remove(item.path)
                }
            })
    }
}

// MARK: - Dev Artifact Patterns

struct DevArtifactPattern: Sendable {
    let name: String
    let directoryName: String
    let siblingIndicators: [String]  // Files that indicate this is a project root
    /// Which per-project browser bucket (ProjectScanner.discoverProjects) this
    /// artifact belongs to. `nil` marks machine-global caches (ms-playwright,
    /// .pnpm-store) that aren't tied to a single project root and so never appear
    /// in the per-project breakdown.
    let projectType: ProjectType?
    var fileExtension: String?

    func matches(_ url: URL) -> Bool {
        if let fileExtension {
            guard url.pathExtension == fileExtension else { return false }
        } else {
            guard url.lastPathComponent == directoryName else { return false }
        }

        // Check for sibling files that indicate a project root
        let parent = url.deletingLastPathComponent()

        for indicator in siblingIndicators {
            if Self.parentContainsFile(matching: indicator, in: parent) {
                return true
            }
        }

        // If no indicators specified, just match the directory name
        return siblingIndicators.isEmpty
    }

    /// Sibling-indicator match. `fileExists` does NOT interpret shell globs, so a
    /// `"*.csproj"` indicator (used by the .NET/Xcode patterns) would look for a
    /// file literally named `*.csproj` and never match. For a `*.ext` glob we
    /// enumerate the directory and match by suffix; everything else keeps the fast
    /// exact-name `fileExists` path.
    static func parentContainsFile(matching glob: String, in parent: URL) -> Bool {
        guard glob.contains("*") else {
            return ScanFileSystem.exists(atPath: parent.appending(path: glob).path)
        }
        let entries = (try? ScanFileSystem.contentsOfDirectory(atPath: parent.path)) ?? []
        return entries.contains { indicator(glob, matchesFilename: $0) }
    }

    /// Whether `filename` satisfies an indicator entry: exact name, or suffix
    /// match for the "*.ext" glob form the .NET/Xcode indicators use.
    static func indicator(_ indicator: String, matchesFilename filename: String) -> Bool {
        guard let wildcard = indicator.firstIndex(of: "*") else { return filename == indicator }
        let prefix = String(indicator[..<wildcard])
        let suffix = String(indicator[indicator.index(after: wildcard)...])
        return filename.count >= prefix.count + suffix.count && filename.hasPrefix(prefix) && filename.hasSuffix(suffix)
    }

    /// Project type for a file that marks a project root, derived from
    /// `allPatterns` so the per-project browser (ProjectScanner.discoverProjects)
    /// can never drift from the cleanup scan's table again. Returns nil for
    /// filenames that are no pattern's sibling indicator.
    static func projectType(forRootIndicator filename: String) -> ProjectType? {
        for pattern in allPatterns {
            guard let type = pattern.projectType else { continue }
            if pattern.siblingIndicators.contains(where: { indicator($0, matchesFilename: filename) }) {
                return type
            }
        }
        return nil
    }

    /// Every artifact directory to check inside a project root of the given type,
    /// derived from `allPatterns` (order-preserving, deduplicated). Includes
    /// empty-indicator patterns like `__pycache__` — they can't act as root
    /// indicators but still belong to their ecosystem's artifact list — plus the
    /// path-shaped extras `matches(_:)`'s lastPathComponent comparison can't
    /// express (Ruby's vendor/bundle).
    static func artifactDirectories(for type: ProjectType) -> [String] {
        var seen = Set<String>()
        var directories: [String] = []
        for pattern in allPatterns where pattern.projectType == type && pattern.fileExtension == nil {
            if seen.insert(pattern.directoryName).inserted {
                directories.append(pattern.directoryName)
            }
        }
        for extra in extraArtifactDirectories[type] ?? [] where seen.insert(extra).inserted {
            directories.append(extra)
        }
        return directories
    }

    /// Artifact locations that are relative paths rather than directory names, so
    /// they can't live in `allPatterns` (whose `matches(_:)` compares a single
    /// path component).
    private static let extraArtifactDirectories: [ProjectType: [String]] = [
        .ruby: ["vendor/bundle"]
    ]

    static let allPatterns: [DevArtifactPattern] = [
        DevArtifactPattern(name: "TypeScript build info", directoryName: "tsbuildinfo",
                           siblingIndicators: ["tsconfig*.json", "package.json"], projectType: .nodejs,
                           fileExtension: "tsbuildinfo"),
        // JavaScript/TypeScript
        DevArtifactPattern(
            name: "node_modules",
            directoryName: "node_modules",
            siblingIndicators: ["package.json"],
            projectType: .nodejs
        ),

        // Swift Package Manager
        DevArtifactPattern(
            name: "Swift .build",
            directoryName: ".build",
            siblingIndicators: ["Package.swift"],
            projectType: .swift
        ),

        // CocoaPods
        DevArtifactPattern(
            name: "CocoaPods",
            directoryName: "Pods",
            siblingIndicators: ["Podfile"],
            projectType: .xcode
        ),

        // Rust
        DevArtifactPattern(
            name: "Rust target",
            directoryName: "target",
            siblingIndicators: ["Cargo.toml"],
            projectType: .rust
        ),

        // Python
        DevArtifactPattern(
            name: "Python __pycache__",
            directoryName: "__pycache__",
            siblingIndicators: [],  // Can appear anywhere
            projectType: .python
        ),
        DevArtifactPattern(
            name: "Python .venv",
            directoryName: ".venv",
            siblingIndicators: ["requirements.txt", "pyproject.toml", "setup.py"],
            projectType: .python
        ),
        DevArtifactPattern(
            name: "Python venv",
            directoryName: "venv",
            siblingIndicators: ["requirements.txt", "pyproject.toml", "setup.py"],
            projectType: .python
        ),
        DevArtifactPattern(
            name: "pytest cache",
            directoryName: ".pytest_cache",
            siblingIndicators: ["pytest.ini", "pyproject.toml", "setup.py"],
            projectType: .python
        ),
        DevArtifactPattern(
            name: "mypy cache",
            directoryName: ".mypy_cache",
            siblingIndicators: ["pyproject.toml", "setup.py", "mypy.ini", ".mypy.ini"],
            projectType: .python
        ),

        // Gradle (Android/Java)
        DevArtifactPattern(
            name: "Gradle .gradle",
            directoryName: ".gradle",
            siblingIndicators: ["build.gradle", "build.gradle.kts", "settings.gradle"],
            projectType: .java
        ),
        DevArtifactPattern(
            name: "Gradle build",
            directoryName: "build",
            siblingIndicators: ["build.gradle", "build.gradle.kts"],
            projectType: .java
        ),

        // Go
        DevArtifactPattern(
            name: "Go vendor",
            directoryName: "vendor",
            siblingIndicators: ["go.mod"],
            projectType: .go
        ),

        // PHP
        DevArtifactPattern(
            name: "PHP vendor",
            directoryName: "vendor",
            siblingIndicators: ["composer.json"],
            projectType: .php
        ),

        // Ruby
        DevArtifactPattern(
            name: "Ruby .bundle",
            directoryName: ".bundle",
            siblingIndicators: ["Gemfile"],
            projectType: .ruby
        ),

        // .NET
        DevArtifactPattern(
            name: ".NET bin",
            directoryName: "bin",
            siblingIndicators: ["*.csproj", "*.fsproj"],
            projectType: .dotnet
        ),
        DevArtifactPattern(
            name: ".NET obj",
            directoryName: "obj",
            siblingIndicators: ["*.csproj", "*.fsproj"],
            projectType: .dotnet
        ),

        // Xcode (project-specific)
        DevArtifactPattern(
            name: "Xcode build",
            directoryName: "build",
            siblingIndicators: ["*.xcodeproj", "*.xcworkspace"],
            projectType: .xcode
        ),

        // CMake
        DevArtifactPattern(
            name: "CMake build",
            directoryName: "build",
            siblingIndicators: ["CMakeLists.txt"],
            projectType: .cmake
        ),

        // Bun
        DevArtifactPattern(
            name: "Bun lockfile",
            directoryName: "node_modules",
            siblingIndicators: ["bun.lockb"],
            projectType: .nodejs
        ),

        // Next.js
        DevArtifactPattern(
            name: "Next.js build",
            directoryName: ".next",
            siblingIndicators: ["next.config.js", "next.config.mjs", "next.config.ts", "package.json"],
            projectType: .nodejs
        ),

        // Nuxt.js
        DevArtifactPattern(
            name: "Nuxt.js build",
            directoryName: ".nuxt",
            siblingIndicators: ["nuxt.config.js", "nuxt.config.ts"],
            projectType: .nodejs
        ),

        // Turborepo
        DevArtifactPattern(
            name: "Turbo cache",
            directoryName: ".turbo",
            siblingIndicators: ["turbo.json"],
            projectType: .nodejs
        ),

        // General dist/build output
        DevArtifactPattern(
            name: "dist folder",
            directoryName: "dist",
            siblingIndicators: ["package.json", "tsconfig.json"],
            projectType: .nodejs
        ),

        // Parcel
        DevArtifactPattern(
            name: "Parcel cache",
            directoryName: ".parcel-cache",
            siblingIndicators: ["package.json"],
            projectType: .nodejs
        ),

        // Vite
        DevArtifactPattern(
            name: "Vite cache",
            directoryName: ".vite",
            siblingIndicators: ["vite.config.js", "vite.config.ts"],
            projectType: .nodejs
        ),

        // ESLint
        DevArtifactPattern(
            name: "ESLint cache",
            directoryName: ".eslintcache",
            siblingIndicators: [".eslintrc.js", ".eslintrc.json", "eslint.config.js"],
            projectType: .nodejs
        ),

        // General cache directories
        DevArtifactPattern(
            name: "Cache folder",
            directoryName: ".cache",
            siblingIndicators: ["package.json"],
            projectType: .nodejs
        ),

        // Bun
        DevArtifactPattern(
            name: "Bun cache",
            directoryName: ".bun",
            siblingIndicators: ["bun.lockb", "bun.lock"],
            projectType: .nodejs
        ),

        // pnpm
        DevArtifactPattern(
            name: "pnpm store",
            directoryName: ".pnpm-store",
            siblingIndicators: [],
            projectType: nil  // machine-global store, not a per-project artifact
        ),
        DevArtifactPattern(
            name: "pnpm virtual store",
            directoryName: ".pnpm",
            siblingIndicators: ["pnpm-lock.yaml"],
            projectType: .nodejs
        ),

        // Playwright browsers
        DevArtifactPattern(
            name: "Playwright browsers",
            directoryName: "ms-playwright",
            siblingIndicators: [],
            projectType: nil  // machine-global cache, not a per-project artifact
        ),

        // Cypress
        DevArtifactPattern(
            name: "Cypress cache",
            directoryName: ".cypress",
            siblingIndicators: ["cypress.config.js", "cypress.config.ts"],
            projectType: .nodejs
        ),

        // Biome
        DevArtifactPattern(
            name: "Biome cache",
            directoryName: ".biome",
            siblingIndicators: ["biome.json", "biome.jsonc"],
            projectType: .nodejs
        ),

        // Webpack
        DevArtifactPattern(
            name: "Webpack cache",
            directoryName: ".webpack",
            siblingIndicators: ["webpack.config.js", "webpack.config.ts"],
            projectType: .nodejs
        ),

        // Storybook
        DevArtifactPattern(
            name: "Storybook cache",
            directoryName: ".storybook-cache",
            siblingIndicators: [".storybook"],
            projectType: .nodejs
        ),

        // Angular
        DevArtifactPattern(
            name: "Angular cache",
            directoryName: ".angular",
            siblingIndicators: ["angular.json"],
            projectType: .nodejs
        ),

        // Nx
        DevArtifactPattern(
            name: "Nx cache",
            directoryName: ".nx",
            siblingIndicators: ["nx.json"],
            projectType: .nodejs
        ),

        // Yarn
        DevArtifactPattern(
            name: "Yarn cache",
            directoryName: ".yarn",
            siblingIndicators: [".yarnrc.yml"],
            projectType: .nodejs
        ),

        // Coverage reports
        DevArtifactPattern(
            name: "Coverage reports",
            directoryName: "coverage",
            siblingIndicators: ["package.json", "vitest.config.ts", "jest.config.js"],
            projectType: .nodejs
        ),
    ]
}

// MARK: - Project Discovery

struct ProjectInfo: Identifiable {
    let id = UUID()
    let path: URL
    let type: ProjectType
    let artifactPaths: [URL]
    var artifactSize: Int64 = 0
    var lastModified: Date?

    var name: String {
        path.lastPathComponent
    }

    var formattedSize: String {
        artifactSize.formattedFileSize
    }

    /// Whether the project was modified within the last 24 hours
    var isRecentlyModified: Bool {
        guard let lastModified = lastModified else { return false }
        let hoursSinceModified = Date().timeIntervalSince(lastModified) / 3600
        return hoursSinceModified < 24
    }

    /// Whether the project was modified within the last 48 hours (warning threshold)
    var isModifiedRecently: Bool {
        guard let lastModified = lastModified else { return false }
        let hoursSinceModified = Date().timeIntervalSince(lastModified) / 3600
        return hoursSinceModified < 48
    }

    /// Human-readable time since last modification
    var timeSinceModified: String? {
        guard let lastModified = lastModified else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastModified, relativeTo: Date())
    }

    /// Command to regenerate the artifacts
    var regenerateCommand: String {
        type.regenerateCommand
    }
}

enum ProjectType: String, CaseIterable {
    case nodejs = "Node.js"
    case swift = "Swift"
    case rust = "Rust"
    case python = "Python"
    case java = "Java/Gradle"
    case xcode = "Xcode"
    case go = "Go"
    case ruby = "Ruby"
    case php = "PHP"
    case dotnet = ".NET"
    case cmake = "CMake"

    var icon: String {
        switch self {
        case .nodejs: return "cube.box"
        case .swift: return "swift"
        case .rust: return "gearshape.2"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .java: return "cup.and.saucer"
        case .xcode: return "hammer"
        case .go: return "figure.run"
        case .ruby: return "diamond"
        case .php: return "globe"
        case .dotnet: return "network"
        case .cmake: return "triangle"
        }
    }

    var regenerateCommand: String {
        switch self {
        case .nodejs: return "npm install"
        case .swift: return "swift build"
        case .rust: return "cargo build"
        case .python: return "pip install -r requirements.txt"
        case .java: return "./gradlew build"
        case .xcode: return "xcodebuild"
        case .go: return "go build"
        case .ruby: return "bundle install"
        case .php: return "composer install"
        case .dotnet: return "dotnet build"
        case .cmake: return "cmake -B build && cmake --build build"
        }
    }
}

actor ProjectScanner {
    static let defaultMaxDepth = DevToolsModule.defaultMaxDepth

    /// Discover projects with cleanable artifacts.
    ///
    /// Root indicators and per-type artifact directories are derived from
    /// `DevArtifactPattern.allPatterns` (via each pattern's `projectType`), so
    /// this browser can't drift from the cleanup scan's table. A directory
    /// carrying two indicator files of the same type (Podfile + *.xcodeproj) is
    /// one project; indicators of different types (package.json + Cargo.toml)
    /// keep one entry per type, as the old hand-written table did.
    static func projects(from items: [CleanupItem]) -> [ProjectInfo] {
        var grouped: [String: [CleanupItem]] = [:]
        for item in items {
            guard let receipt = item.devArtifactReceipt, let type = receipt.projectType else { continue }
            grouped[receipt.project.standardizedFileURL.path + "|" + type.rawValue, default: []].append(item)
        }
        return grouped.values.compactMap { artifacts in
            guard let receipt = artifacts.first?.devArtifactReceipt, let type = receipt.projectType else { return nil }
            var project = ProjectInfo(path: receipt.project, type: type, artifactPaths: artifacts.map(\.path))
            project.artifactSize = artifacts.reduce(0) { $0 + $1.size }
            project.lastModified = artifacts.compactMap(\.contentModificationDate).max()
            return project
        }.sorted { $0.artifactSize > $1.artifactSize }
    }

    func discoverProjects(
        in baseURL: URL,
        maxDepth: Int = ProjectScanner.defaultMaxDepth
    ) async -> [ProjectInfo] {
        var all: [ProjectInfo] = []
        for root in DeveloperScanRoots.paths(in: baseURL) {
            all.append(contentsOf: await discoverProjectsAtRoot(in: root, maxDepth: maxDepth))
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.path.standardizedFileURL.path + $0.type.rawValue).inserted }
    }

    private func discoverProjectsAtRoot(in baseURL: URL, maxDepth: Int) async -> [ProjectInfo] {
        var projects: [ProjectInfo] = []
        var seenProjects = Set<String>()
        let checker = SafetyChecker()

        guard let enumerator = ScanFileSystem.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return projects }
            let depth = url.pathComponents.count - baseURL.pathComponents.count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            // Skip node_modules, vendor, etc.
            let name = url.lastPathComponent
            if name == "node_modules" || name == "vendor" || name == ".git" || name == "Library" {
                enumerator.skipDescendants()
                continue
            }

            guard let projectType = DevArtifactPattern.projectType(forRootIndicator: name) else { continue }

            let projectPath = url.deletingLastPathComponent()
            let projectKey = "\(projectPath.path)|\(projectType.rawValue)"
            guard !seenProjects.contains(projectKey) else { continue }

            // Find artifact directories
            var artifacts: [URL] = []
            var totalSize: Int64 = 0
            var mostRecentModification: Date?

            for artifactDir in DevArtifactPattern.artifactDirectories(for: projectType) {
                let artifactPath = projectPath.appending(path: artifactDir)
                guard ScanFileSystem.exists(atPath: artifactPath.path) else { continue }
                // Same gate scanForPatterns applies (DevToolsModule.scan): a
                // protected path must not become listable/selectable in the
                // per-project browser UI.
                guard checker.validateForScan(artifactPath, moduleID: "dev-tools").isSafe else { continue }

                artifacts.append(artifactPath)
                totalSize += (try? await DiskAnalyzer.directorySize(at: artifactPath)) ?? 0

                // Track most recent modification
                if let modDate = try? artifactPath.scanResourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    if mostRecentModification == nil || modDate > mostRecentModification! {
                        mostRecentModification = modDate
                    }
                }
            }

            // Also check the project indicator file's modification date
            if let indicatorModDate = try? url.scanResourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if mostRecentModification == nil || indicatorModDate > mostRecentModification! {
                    mostRecentModification = indicatorModDate
                }
            }

            if !artifacts.isEmpty {
                seenProjects.insert(projectKey)
                var project = ProjectInfo(
                    path: projectPath,
                    type: projectType,
                    artifactPaths: artifacts
                )
                project.artifactSize = totalSize
                project.lastModified = mostRecentModification
                projects.append(project)
            }
        }

        return projects.sorted { $0.artifactSize > $1.artifactSize }
    }
}
