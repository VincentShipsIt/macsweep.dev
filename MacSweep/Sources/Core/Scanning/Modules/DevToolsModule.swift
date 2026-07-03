import Foundation

/// Module for cleaning up developer tool artifacts
struct DevToolsModule: ScanModule {
    let id = "dev-tools"
    let name = "Developer Tools"
    let description = "Clean node_modules, DerivedData, build artifacts"
    let icon = "wrench.and.screwdriver"

    /// Search paths for dev artifacts
    var searchPaths: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
    ]

    /// Maximum depth to search for projects
    var maxDepth: Int = 6

    func scan() async throws -> [CleanupItem] {
        var items: [CleanupItem] = []

        let patterns = DevArtifactPattern.allPatterns

        for searchPath in searchPaths {
            let found = await scanForPatterns(patterns, in: searchPath)
            items.append(contentsOf: found)
        }

        // Fixed Xcode / tooling cache locations under ~/Library, gated by the
        // shared exists+size helper.
        //
        // npm / pnpm / Bun / pip / cargo / Homebrew caches are intentionally NOT
        // scanned here. PackageManagerModule already covers them with correctly
        // SCOPED paths (~/.npm/_cacache, ~/.cargo/registry/cache, …). DevTools
        // previously registered the broad parents (whole ~/.npm, all of
        // ~/.cargo/registry — which also holds the `src/` tarballs cargo needs),
        // double-counting the same bytes and risking over-deletion.
        let library = URL.libraryDirectory
        let fixedTargets: [(path: String, name: String)] = [
            ("Developer/Xcode/DerivedData", "Xcode DerivedData"),
            ("Developer/Xcode/Archives", "Xcode Archives"),
            ("Developer/Xcode/iOS DeviceSupport", "iOS Device Support"),
            ("Caches/ms-playwright", "Playwright Browsers"),
            ("Developer/CoreSimulator/Devices", "iOS Simulators"),
        ]
        for target in fixedTargets {
            if let item = await scanCacheDirectory(at: library.appending(path: target.path), moduleName: target.name) {
                items.append(item)
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    private func scanForPatterns(_ patterns: [DevArtifactPattern], in baseURL: URL) async -> [CleanupItem] {
        var items: [CleanupItem] = []

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            // Depth is derived inline from path components on each visit.
            let pathComponents = url.pathComponents.count - baseURL.pathComponents.count
            if pathComponents > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            // Skip certain directories to speed up scanning
            let name = url.lastPathComponent
            if name == ".git" || name == ".svn" || name == "Library" {
                enumerator.skipDescendants()
                continue
            }

            // Check against patterns
            for pattern in patterns {
                if pattern.matches(url) {
                    // Safety check
                    let checker = SafetyChecker()
                    guard checker.validateForScan(url, moduleID: id).isSafe else { continue }

                    let size = (try? await DiskAnalyzer.directorySize(at: url)) ?? 0
                    guard size > 1_048_576 else { continue }  // Skip if < 1MB

                    items.append(CleanupItem(
                        id: UUID(),
                        path: url,
                        size: size,
                        type: .directory,
                        module: id,
                        moduleName: pattern.name
                    ))

                    // Don't descend into matched directories
                    enumerator.skipDescendants()
                    break
                }
            }
        }

        return items
    }

    func clean(items: [CleanupItem], dryRun: Bool) async throws -> CleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []
        let checker = SafetyChecker()

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
            } else {
                // Defense-in-depth: re-validate every item before deleting,
                // even though scan() already filtered to safe paths.
                guard checker.validateForCleanup(item.path, moduleID: id, itemType: item.type).isSafe else {
                    errors.append(CleanupError(
                        path: item.path,
                        message: "Blocked by safety checks"
                    ))
                    continue
                }
                do {
                    try FileManager.default.trashItem(at: item.path, resultingItemURL: nil)
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

// MARK: - Dev Artifact Patterns

struct DevArtifactPattern {
    let name: String
    let directoryName: String
    let siblingIndicators: [String]  // Files that indicate this is a project root

    func matches(_ url: URL) -> Bool {
        guard url.lastPathComponent == directoryName else { return false }

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
    private static func parentContainsFile(matching glob: String, in parent: URL) -> Bool {
        guard glob.hasPrefix("*.") else {
            return FileManager.default.fileExists(atPath: parent.appending(path: glob).path)
        }
        let suffix = String(glob.dropFirst(1))   // "*.csproj" -> ".csproj"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        return entries.contains { $0.hasSuffix(suffix) }
    }

    static let allPatterns: [DevArtifactPattern] = [
        // JavaScript/TypeScript
        DevArtifactPattern(
            name: "node_modules",
            directoryName: "node_modules",
            siblingIndicators: ["package.json"]
        ),

        // Swift Package Manager
        DevArtifactPattern(
            name: "Swift .build",
            directoryName: ".build",
            siblingIndicators: ["Package.swift"]
        ),

        // CocoaPods
        DevArtifactPattern(
            name: "CocoaPods",
            directoryName: "Pods",
            siblingIndicators: ["Podfile"]
        ),

        // Rust
        DevArtifactPattern(
            name: "Rust target",
            directoryName: "target",
            siblingIndicators: ["Cargo.toml"]
        ),

        // Python
        DevArtifactPattern(
            name: "Python __pycache__",
            directoryName: "__pycache__",
            siblingIndicators: []  // Can appear anywhere
        ),
        DevArtifactPattern(
            name: "Python .venv",
            directoryName: ".venv",
            siblingIndicators: ["requirements.txt", "pyproject.toml", "setup.py"]
        ),
        DevArtifactPattern(
            name: "Python venv",
            directoryName: "venv",
            siblingIndicators: ["requirements.txt", "pyproject.toml", "setup.py"]
        ),
        DevArtifactPattern(
            name: "pytest cache",
            directoryName: ".pytest_cache",
            siblingIndicators: ["pytest.ini", "pyproject.toml", "setup.py"]
        ),
        DevArtifactPattern(
            name: "mypy cache",
            directoryName: ".mypy_cache",
            siblingIndicators: ["pyproject.toml", "setup.py", "mypy.ini", ".mypy.ini"]
        ),

        // Gradle (Android/Java)
        DevArtifactPattern(
            name: "Gradle .gradle",
            directoryName: ".gradle",
            siblingIndicators: ["build.gradle", "build.gradle.kts", "settings.gradle"]
        ),
        DevArtifactPattern(
            name: "Gradle build",
            directoryName: "build",
            siblingIndicators: ["build.gradle", "build.gradle.kts"]
        ),

        // Go
        DevArtifactPattern(
            name: "Go vendor",
            directoryName: "vendor",
            siblingIndicators: ["go.mod"]
        ),

        // PHP
        DevArtifactPattern(
            name: "PHP vendor",
            directoryName: "vendor",
            siblingIndicators: ["composer.json"]
        ),

        // Ruby
        DevArtifactPattern(
            name: "Ruby .bundle",
            directoryName: ".bundle",
            siblingIndicators: ["Gemfile"]
        ),

        // .NET
        DevArtifactPattern(
            name: ".NET bin",
            directoryName: "bin",
            siblingIndicators: ["*.csproj", "*.fsproj"]
        ),
        DevArtifactPattern(
            name: ".NET obj",
            directoryName: "obj",
            siblingIndicators: ["*.csproj", "*.fsproj"]
        ),

        // Xcode (project-specific)
        DevArtifactPattern(
            name: "Xcode build",
            directoryName: "build",
            siblingIndicators: ["*.xcodeproj", "*.xcworkspace"]
        ),

        // CMake
        DevArtifactPattern(
            name: "CMake build",
            directoryName: "build",
            siblingIndicators: ["CMakeLists.txt"]
        ),

        // Bun
        DevArtifactPattern(
            name: "Bun lockfile",
            directoryName: "node_modules",
            siblingIndicators: ["bun.lockb"]
        ),

        // Next.js
        DevArtifactPattern(
            name: "Next.js build",
            directoryName: ".next",
            siblingIndicators: ["next.config.js", "next.config.mjs", "next.config.ts"]
        ),

        // Nuxt.js
        DevArtifactPattern(
            name: "Nuxt.js build",
            directoryName: ".nuxt",
            siblingIndicators: ["nuxt.config.js", "nuxt.config.ts"]
        ),

        // Turborepo
        DevArtifactPattern(
            name: "Turbo cache",
            directoryName: ".turbo",
            siblingIndicators: ["turbo.json"]
        ),

        // General dist/build output
        DevArtifactPattern(
            name: "dist folder",
            directoryName: "dist",
            siblingIndicators: ["package.json", "tsconfig.json"]
        ),

        // Parcel
        DevArtifactPattern(
            name: "Parcel cache",
            directoryName: ".parcel-cache",
            siblingIndicators: ["package.json"]
        ),

        // Vite
        DevArtifactPattern(
            name: "Vite cache",
            directoryName: ".vite",
            siblingIndicators: ["vite.config.js", "vite.config.ts"]
        ),

        // ESLint
        DevArtifactPattern(
            name: "ESLint cache",
            directoryName: ".eslintcache",
            siblingIndicators: [".eslintrc.js", ".eslintrc.json", "eslint.config.js"]
        ),

        // General cache directories
        DevArtifactPattern(
            name: "Cache folder",
            directoryName: ".cache",
            siblingIndicators: ["package.json"]
        ),

        // Bun
        DevArtifactPattern(
            name: "Bun cache",
            directoryName: ".bun",
            siblingIndicators: ["bun.lockb", "bun.lock"]
        ),

        // pnpm
        DevArtifactPattern(
            name: "pnpm store",
            directoryName: ".pnpm-store",
            siblingIndicators: []
        ),
        DevArtifactPattern(
            name: "pnpm virtual store",
            directoryName: ".pnpm",
            siblingIndicators: ["pnpm-lock.yaml"]
        ),

        // Playwright browsers
        DevArtifactPattern(
            name: "Playwright browsers",
            directoryName: "ms-playwright",
            siblingIndicators: []
        ),

        // Cypress
        DevArtifactPattern(
            name: "Cypress cache",
            directoryName: ".cypress",
            siblingIndicators: ["cypress.config.js", "cypress.config.ts"]
        ),

        // Biome
        DevArtifactPattern(
            name: "Biome cache",
            directoryName: ".biome",
            siblingIndicators: ["biome.json", "biome.jsonc"]
        ),

        // Webpack
        DevArtifactPattern(
            name: "Webpack cache",
            directoryName: ".webpack",
            siblingIndicators: ["webpack.config.js", "webpack.config.ts"]
        ),

        // Storybook
        DevArtifactPattern(
            name: "Storybook cache",
            directoryName: ".storybook-cache",
            siblingIndicators: [".storybook"]
        ),

        // Angular
        DevArtifactPattern(
            name: "Angular cache",
            directoryName: ".angular",
            siblingIndicators: ["angular.json"]
        ),

        // Nx
        DevArtifactPattern(
            name: "Nx cache",
            directoryName: ".nx",
            siblingIndicators: ["nx.json"]
        ),

        // Yarn
        DevArtifactPattern(
            name: "Yarn cache",
            directoryName: ".yarn",
            siblingIndicators: [".yarnrc.yml"]
        ),

        // Coverage reports
        DevArtifactPattern(
            name: "Coverage reports",
            directoryName: "coverage",
            siblingIndicators: ["package.json", "vitest.config.ts", "jest.config.js"]
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
        ByteCountFormatter.string(fromByteCount: artifactSize, countStyle: .file)
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
        }
    }
}

actor ProjectScanner {
    /// Discover projects with cleanable artifacts
    func discoverProjects(in baseURL: URL, maxDepth: Int = 5) async -> [ProjectInfo] {
        var projects: [ProjectInfo] = []

        let projectIndicators: [(String, ProjectType, [String])] = [
            ("package.json", .nodejs, ["node_modules", ".next", ".nuxt", ".turbo", "dist", ".cache", ".parcel-cache", ".bun"]),
            ("Package.swift", .swift, [".build"]),
            ("Cargo.toml", .rust, ["target"]),
            ("requirements.txt", .python, [".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache"]),
            ("pyproject.toml", .python, [".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache"]),
            ("build.gradle", .java, [".gradle", "build"]),
            ("build.gradle.kts", .java, [".gradle", "build"]),
            ("go.mod", .go, ["vendor"]),
            ("Gemfile", .ruby, [".bundle", "vendor/bundle"]),
            ("composer.json", .php, ["vendor"]),
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
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

            // Check for project indicators
            for (indicator, projectType, artifactDirs) in projectIndicators {
                if name == indicator {
                    let projectPath = url.deletingLastPathComponent()

                    // Find artifact directories
                    var artifacts: [URL] = []
                    var totalSize: Int64 = 0
                    var mostRecentModification: Date?

                    for artifactDir in artifactDirs {
                        let artifactPath = projectPath.appending(path: artifactDir)
                        if FileManager.default.fileExists(atPath: artifactPath.path) {
                            artifacts.append(artifactPath)
                            totalSize += (try? await DiskAnalyzer.directorySize(at: artifactPath)) ?? 0

                            // Track most recent modification
                            if let modDate = try? artifactPath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                                if mostRecentModification == nil || modDate > mostRecentModification! {
                                    mostRecentModification = modDate
                                }
                            }
                        }
                    }

                    // Also check the project indicator file's modification date
                    if let indicatorModDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                        if mostRecentModification == nil || indicatorModDate > mostRecentModification! {
                            mostRecentModification = indicatorModDate
                        }
                    }

                    if !artifacts.isEmpty {
                        var project = ProjectInfo(
                            path: projectPath,
                            type: projectType,
                            artifactPaths: artifacts
                        )
                        project.artifactSize = totalSize
                        project.lastModified = mostRecentModification
                        projects.append(project)
                    }

                    break
                }
            }
        }

        return projects.sorted { $0.artifactSize > $1.artifactSize }
    }
}

// MARK: - Git Artifact Discovery

enum GitCleanupKind: String, Sendable {
    case worktree = "Worktree"
    case branch = "Branch"

    var icon: String {
        switch self {
        case .worktree: return "folder.badge.gearshape"
        case .branch: return "arrow.triangle.branch"
        }
    }
}

struct GitCleanupItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: GitCleanupKind
    let repositoryPath: URL
    let displayPath: URL?
    let branchName: String?
    let size: Int64
    let lastActivity: Date?
    let reason: String
    let commandPreview: String

    init(
        id: UUID = UUID(),
        kind: GitCleanupKind,
        repositoryPath: URL,
        displayPath: URL?,
        branchName: String?,
        size: Int64,
        lastActivity: Date?,
        reason: String,
        commandPreview: String
    ) {
        self.id = id
        self.kind = kind
        self.repositoryPath = repositoryPath
        self.displayPath = displayPath
        self.branchName = branchName
        self.size = size
        self.lastActivity = lastActivity
        self.reason = reason
        self.commandPreview = commandPreview
    }

    var name: String {
        switch kind {
        case .worktree:
            return displayPath?.lastPathComponent ?? "Git worktree"
        case .branch:
            return branchName ?? "Git branch"
        }
    }

    var formattedSize: String {
        guard size > 0 else { return "No disk data" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var timeSinceActivity: String? {
        guard let lastActivity else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastActivity, relativeTo: Date())
    }
}

struct GitCleanupResult: Sendable {
    let itemsProcessed: Int
    let bytesFreed: Int64
    let errors: [CleanupError]
}

struct GitToolStatus: Sendable {
    let gitPath: String?
    let ghPath: String?
    let ghAuthenticated: Bool

    var canUseGitHubCLI: Bool {
        ghPath != nil && ghAuthenticated
    }
}

struct GitArtifactScanner: Sendable {
    var searchPaths: [URL]
    var maxDepth: Int
    var staleInterval: TimeInterval
    var includeGitHubState: Bool

    init(
        searchPaths: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        maxDepth: Int = 5,
        staleInterval: TimeInterval = 14 * 24 * 60 * 60,
        includeGitHubState: Bool = true
    ) {
        self.searchPaths = searchPaths
        self.maxDepth = maxDepth
        self.staleInterval = staleInterval
        self.includeGitHubState = includeGitHubState
    }

    func toolStatus() async -> GitToolStatus {
        let git = Self.executablePath(for: "git")
        let gh = Self.executablePath(for: "gh")
        let ghAuthenticated: Bool
        if gh != nil {
            ghAuthenticated = Self.run(["gh", "auth", "status"]).status == 0
        } else {
            ghAuthenticated = false
        }
        return GitToolStatus(gitPath: git, ghPath: gh, ghAuthenticated: ghAuthenticated)
    }

    func discoverStaleArtifacts() async -> [GitCleanupItem] {
        guard Self.executablePath(for: "git") != nil else { return [] }

        let status = await toolStatus()
        let roots = discoverRepositoryRoots()
        var seenCommonDirectories = Set<String>()
        var items: [GitCleanupItem] = []

        for root in roots {
            guard let repository = Self.repository(at: root) else { continue }
            guard seenCommonDirectories.insert(repository.commonDirectory.path).inserted else { continue }

            let checkedOutBranches = Self.checkedOutBranches(in: repository.root)
            let staleWorktrees = await discoverStaleWorktrees(
                in: repository,
                checkedOutBranches: checkedOutBranches,
                ghAvailable: status.canUseGitHubCLI
            )
            let staleBranches = await discoverStaleBranches(
                in: repository,
                checkedOutBranches: checkedOutBranches,
                ghAvailable: status.canUseGitHubCLI
            )

            items.append(contentsOf: staleWorktrees)
            items.append(contentsOf: staleBranches)
        }

        return items.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.size > $1.size
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private func discoverRepositoryRoots() -> [URL] {
        var roots: [URL] = []
        var seen = Set<String>()

        for path in candidateSearchPaths() {
            for root in Self.repositoryRoots(in: path, maxDepth: maxDepth, skipHidden: path.lastPathComponent != ".codex") {
                let standardized = root.standardizedFileURL.path
                if seen.insert(standardized).inserted {
                    roots.append(root)
                }
            }
        }

        return roots
    }

    private func candidateSearchPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hiddenWorktreeRoots = [
            home.appending(path: ".codex/worktrees", directoryHint: .isDirectory),
            home.appending(path: ".claude/worktrees", directoryHint: .isDirectory),
            home.appending(path: ".agents/worktrees", directoryHint: .isDirectory)
        ]

        return (searchPaths + hiddenWorktreeRoots).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func discoverStaleWorktrees(
        in repository: GitRepository,
        checkedOutBranches: Set<String>,
        ghAvailable: Bool
    ) async -> [GitCleanupItem] {
        let entries = Self.parseWorktreeList(Self.run(["git", "-C", repository.root.path, "worktree", "list", "--porcelain"]).output)
        guard !entries.isEmpty else { return [] }

        var items: [GitCleanupItem] = []
        for (index, entry) in entries.enumerated() {
            guard index > 0 else { continue } // never remove the main worktree
            guard let path = entry.path else { continue }
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            guard Self.isCleanWorkingTree(path) else { continue }

            let branch = entry.branchName
            let lastActivity = Self.commitDate(for: entry.head, in: repository.root)
                ?? Self.lastModificationDate(for: path)
            guard isStale(lastActivity) else { continue }

            let staleReason: String?
            if let branch {
                if Self.isProtectedBranch(branch) || branch == repository.defaultBranch {
                    continue
                }
                let branchState = Self.branchRemoteState(
                    branch: branch,
                    repository: repository,
                    ghAvailable: ghAvailable && includeGitHubState
                )
                guard branchState.isSafeToClean else { continue }
                staleReason = branchState.reason
            } else if Self.isEphemeralWorktree(path) {
                staleReason = "Detached worktree in an ephemeral agent worktree root"
            } else {
                continue
            }

            let size = (try? await DiskAnalyzer.directorySize(at: path)) ?? 0
            items.append(GitCleanupItem(
                kind: .worktree,
                repositoryPath: repository.root,
                displayPath: path,
                branchName: branch,
                size: size,
                lastActivity: lastActivity,
                reason: staleReason ?? "Clean worktree with no recent activity",
                commandPreview: "git -C \(Self.shellQuoted(repository.root.path)) worktree remove \(Self.shellQuoted(path.path))"
            ))
        }

        return items
    }

    private func discoverStaleBranches(
        in repository: GitRepository,
        checkedOutBranches: Set<String>,
        ghAvailable: Bool
    ) async -> [GitCleanupItem] {
        let rows = Self.branchRows(in: repository.root)
        guard !rows.isEmpty else { return [] }

        var items: [GitCleanupItem] = []
        for row in rows {
            let branch = row.name
            guard branch != repository.currentBranch else { continue }
            guard branch != repository.defaultBranch else { continue }
            guard !Self.isProtectedBranch(branch) else { continue }
            guard !checkedOutBranches.contains(branch) else { continue }
            guard row.worktreePath == nil || row.worktreePath?.isEmpty == true else { continue }
            guard isStale(row.lastCommitDate) else { continue }

            let branchState = Self.branchRemoteState(
                branch: branch,
                repository: repository,
                branchRow: row,
                ghAvailable: ghAvailable && includeGitHubState
            )
            guard branchState.isSafeToClean else { continue }

            items.append(GitCleanupItem(
                kind: .branch,
                repositoryPath: repository.root,
                displayPath: repository.root,
                branchName: branch,
                size: 0,
                lastActivity: row.lastCommitDate,
                reason: branchState.reason,
                commandPreview: "git -C \(Self.shellQuoted(repository.root.path)) branch -d \(Self.shellQuoted(branch))"
            ))
        }

        return items
    }

    private func isStale(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) >= staleInterval
    }

    static func repositoryRoots(in baseURL: URL, maxDepth: Int, skipHidden: Bool) -> [URL] {
        var roots: [URL] = []
        let options: FileManager.DirectoryEnumerationOptions = skipHidden
            ? [.skipsHiddenFiles, .skipsPackageDescendants]
            : [.skipsPackageDescendants]

        if isRepositoryRoot(baseURL) {
            roots.append(baseURL)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options
        ) else { return roots }

        while let url = enumerator.nextObject() as? URL {
            let depth = url.pathComponents.count - baseURL.pathComponents.count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let name = url.lastPathComponent
            if shouldSkipDirectory(named: name) {
                enumerator.skipDescendants()
                continue
            }

            if isRepositoryRoot(url) {
                roots.append(url)
                enumerator.skipDescendants()
            }
        }

        return roots
    }

    static func parseWorktreeList(_ output: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var current = GitWorktreeEntry()

        func flush() {
            if current.path != nil || current.head != nil || current.branchReference != nil {
                entries.append(current)
            }
            current = GitWorktreeEntry()
        }

        for line in output.components(separatedBy: .newlines) {
            if line.isEmpty {
                flush()
                continue
            }
            if let value = line.removingPrefix("worktree ") {
                if current.path != nil {
                    flush()
                }
                current.path = URL(fileURLWithPath: value)
            } else if let value = line.removingPrefix("HEAD ") {
                current.head = value
            } else if let value = line.removingPrefix("branch ") {
                current.branchReference = value
            } else if line == "detached" {
                current.isDetached = true
            } else if let value = line.removingPrefix("prunable ") {
                current.prunableReason = value
            }
        }
        flush()

        return entries
    }

    static func branchRows(in repositoryRoot: URL) -> [GitBranchRow] {
        let format = "%(refname:short)%09%(committerdate:iso8601-strict)%09%(upstream:short)%09%(upstream:track)%09%(worktreepath)"
        let result = run(["git", "-C", repositoryRoot.path, "for-each-ref", "refs/heads", "--format=\(format)"])
        guard result.status == 0 else { return [] }
        return parseBranchRows(result.output)
    }

    static func parseBranchRows(_ output: String) -> [GitBranchRow] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard !line.isEmpty else { return nil }
            let parts = line.components(separatedBy: "\t")
            guard let name = parts.first, !name.isEmpty else { return nil }
            return GitBranchRow(
                name: name,
                lastCommitDate: parts.count > 1 ? parseGitDate(parts[1]) : nil,
                upstream: parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil,
                tracking: parts.count > 3 && !parts[3].isEmpty ? parts[3] : nil,
                worktreePath: parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil
            )
        }
    }

    static func isProtectedBranch(_ branch: String) -> Bool {
        let exact: Set<String> = ["main", "master", "develop", "dev", "trunk", "production", "staging"]
        if exact.contains(branch) { return true }
        return branch.hasPrefix("release/") || branch.hasPrefix("hotfix/")
    }

    private static func repository(at root: URL) -> GitRepository? {
        let topLevel = run(["git", "-C", root.path, "rev-parse", "--show-toplevel"])
        guard topLevel.status == 0 else { return nil }
        let repositoryRoot = URL(fileURLWithPath: topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines))
            .standardizedFileURL

        let common = run(["git", "-C", repositoryRoot.path, "rev-parse", "--git-common-dir"])
        guard common.status == 0 else { return nil }
        let commonText = common.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDirectory: URL
        if commonText.hasPrefix("/") {
            commonDirectory = URL(fileURLWithPath: commonText).standardizedFileURL
        } else {
            commonDirectory = repositoryRoot.appending(path: commonText).standardizedFileURL
        }

        let defaultInfo = defaultBranch(in: repositoryRoot)
        let current = run(["git", "-C", repositoryRoot.path, "branch", "--show-current"])
            .output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GitRepository(
            root: repositoryRoot,
            commonDirectory: commonDirectory,
            defaultBranch: defaultInfo.branch,
            defaultReference: defaultInfo.reference,
            currentBranch: current.isEmpty ? nil : current
        )
    }

    private static func defaultBranch(in repositoryRoot: URL) -> (branch: String?, reference: String?) {
        let originHead = run(["git", "-C", repositoryRoot.path, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
            .output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !originHead.isEmpty {
            let branch = originHead.replacingOccurrences(of: "origin/", with: "")
            if localBranchExists(branch, in: repositoryRoot) {
                return (branch, branch)
            }
            return (branch, originHead)
        }

        for candidate in ["main", "master", "trunk", "develop"] where localBranchExists(candidate, in: repositoryRoot) {
            return (candidate, candidate)
        }

        return (nil, nil)
    }

    private static func localBranchExists(_ branch: String, in repositoryRoot: URL) -> Bool {
        run(["git", "-C", repositoryRoot.path, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]).status == 0
    }

    private static func checkedOutBranches(in repositoryRoot: URL) -> Set<String> {
        Set(parseWorktreeList(run(["git", "-C", repositoryRoot.path, "worktree", "list", "--porcelain"]).output).compactMap(\.branchName))
    }

    private static func branchRemoteState(
        branch: String,
        repository: GitRepository,
        branchRow: GitBranchRow? = nil,
        ghAvailable: Bool
    ) -> BranchStaleState {
        if branchRow?.tracking?.contains("[gone]") == true {
            return BranchStaleState(isSafeToClean: true, reason: "Upstream branch is gone")
        }

        if let defaultReference = repository.defaultReference,
           run(["git", "-C", repository.root.path, "merge-base", "--is-ancestor", branch, defaultReference]).status == 0 {
            return BranchStaleState(isSafeToClean: true, reason: "Merged into \(defaultReference)")
        }

        if ghAvailable, let prState = githubPRState(branch: branch, repositoryRoot: repository.root) {
            switch prState {
            case .merged:
                return BranchStaleState(isSafeToClean: true, reason: "GitHub pull request is merged")
            case .closed:
                return BranchStaleState(isSafeToClean: true, reason: "GitHub pull request is closed")
            case .open:
                return BranchStaleState(isSafeToClean: false, reason: "GitHub pull request is still open")
            }
        }

        return BranchStaleState(isSafeToClean: false, reason: "Branch is not proven merged or closed")
    }

    private static func githubPRState(branch: String, repositoryRoot: URL) -> GitHubPRState? {
        let result = run([
            "gh", "pr", "list",
            "--head", branch,
            "--state", "all",
            "--json", "state,mergedAt,closedAt",
            "--limit", "1"
        ], currentDirectory: repositoryRoot)
        guard result.status == 0, let data = result.output.data(using: .utf8) else { return nil }
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = rows.first,
              let state = first["state"] as? String else { return nil }

        if let mergedAt = first["mergedAt"] as? String, !mergedAt.isEmpty {
            return .merged
        }
        if state.caseInsensitiveCompare("merged") == .orderedSame {
            return .merged
        }
        if state.caseInsensitiveCompare("closed") == .orderedSame {
            return .closed
        }
        if state.caseInsensitiveCompare("open") == .orderedSame {
            return .open
        }
        return nil
    }

    private static func commitDate(for commit: String?, in repositoryRoot: URL) -> Date? {
        guard let commit, !commit.isEmpty else { return nil }
        let result = run(["git", "-C", repositoryRoot.path, "show", "-s", "--format=%cI", commit])
        guard result.status == 0 else { return nil }
        return parseGitDate(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func lastModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func isCleanWorkingTree(_ url: URL) -> Bool {
        run(["git", "-C", url.path, "status", "--porcelain", "--ignore-submodules"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private static func isEphemeralWorktree(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path.hasPrefix(home + "/.codex/worktrees/")
            || path.hasPrefix(home + "/.claude/worktrees/")
            || path.hasPrefix(home + "/.agents/worktrees/")
    }

    private static func isRepositoryRoot(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: ".git").path)
    }

    private static func shouldSkipDirectory(named name: String) -> Bool {
        let skipped: Set<String> = [
            ".git", ".svn", "node_modules", "vendor", ".build", "build",
            "Pods", "DerivedData", "Library", ".Trash", ".Trashes"
        ]
        return skipped.contains(name)
    }

    private static func executablePath(for command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func run(_ arguments: [String], currentDirectory: URL? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return ProcessResult(status: 127, output: "", error: error.localizedDescription)
        }

        // Drain stderr on a separate thread while draining stdout here, then wait.
        // Reading only after waitUntilExit would deadlock once the child fills
        // either pipe's 64 KB buffer — `git status --porcelain` on a dirty tree
        // with many untracked files easily exceeds that. Mirrors the concurrent
        // drain in AssistantConversationService.runProcess.
        let stderrHandle = stderr.fileHandleForReading
        let drainQueue = DispatchQueue(label: "macsweep.devtools.stderr-drain")
        var errorData = Data()
        drainQueue.async { errorData = stderrHandle.readDataToEndOfFile() }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        drainQueue.sync {}   // ensure the stderr drain has completed

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, output: output, error: error)
    }

    private static func parseGitDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: trimmed)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

actor GitArtifactCleaner {
    func clean(items: [GitCleanupItem], dryRun: Bool) async -> GitCleanupResult {
        var processed = 0
        var freed: Int64 = 0
        var errors: [CleanupError] = []

        for item in items {
            if dryRun {
                processed += 1
                freed += item.size
                continue
            }

            switch item.kind {
            case .worktree:
                guard let path = item.displayPath else {
                    errors.append(CleanupError(path: item.repositoryPath, message: "Missing worktree path"))
                    continue
                }

                guard GitArtifactScanner.parseWorktreeList(
                    GitArtifactScanner.run(["git", "-C", item.repositoryPath.path, "worktree", "list", "--porcelain"]).output
                ).contains(where: { $0.path?.standardizedFileURL.path == path.standardizedFileURL.path }) else {
                    errors.append(CleanupError(path: path, message: "Worktree is no longer registered"))
                    continue
                }

                guard GitArtifactScanner.run(["git", "-C", path.path, "status", "--porcelain", "--ignore-submodules"]).output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty else {
                    errors.append(CleanupError(path: path, message: "Worktree has local changes"))
                    continue
                }

                let result = GitArtifactScanner.run(["git", "-C", item.repositoryPath.path, "worktree", "remove", path.path])
                if result.status == 0 {
                    processed += 1
                    freed += item.size
                } else {
                    errors.append(CleanupError(
                        path: path,
                        message: result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "git worktree remove failed"
                            : result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }

            case .branch:
                guard let branch = item.branchName else {
                    errors.append(CleanupError(path: item.repositoryPath, message: "Missing branch name"))
                    continue
                }
                guard !GitArtifactScanner.isProtectedBranch(branch) else {
                    errors.append(CleanupError(path: item.repositoryPath, message: "Protected branch"))
                    continue
                }

                let result = GitArtifactScanner.run(["git", "-C", item.repositoryPath.path, "branch", "-d", branch])
                if result.status == 0 {
                    processed += 1
                } else {
                    errors.append(CleanupError(
                        path: item.repositoryPath,
                        message: result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "git branch -d failed"
                            : result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
        }

        return GitCleanupResult(itemsProcessed: processed, bytesFreed: freed, errors: errors)
    }
}

private struct GitRepository: Sendable {
    let root: URL
    let commonDirectory: URL
    let defaultBranch: String?
    let defaultReference: String?
    let currentBranch: String?
}

struct GitWorktreeEntry: Sendable, Equatable {
    var path: URL?
    var head: String?
    var branchReference: String?
    var isDetached = false
    var prunableReason: String?

    var branchName: String? {
        guard let branchReference else { return nil }
        let prefix = "refs/heads/"
        if branchReference.hasPrefix(prefix) {
            return String(branchReference.dropFirst(prefix.count))
        }
        return branchReference
    }
}

struct GitBranchRow: Sendable, Equatable {
    let name: String
    let lastCommitDate: Date?
    let upstream: String?
    let tracking: String?
    let worktreePath: String?
}

private struct BranchStaleState: Sendable {
    let isSafeToClean: Bool
    let reason: String
}

private enum GitHubPRState: Sendable {
    case open
    case closed
    case merged
}

/// Result of a Process run with separate stdout/stderr. Shared across Core
/// (DevToolsModule + CacheAnalyzer). MalwareScannerService keeps its own type —
/// it merges both streams into a single pipe, so its shape differs.
struct ProcessResult: Sendable {
    let status: Int32
    let output: String
    let error: String
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
