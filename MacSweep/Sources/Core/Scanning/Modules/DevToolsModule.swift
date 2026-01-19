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

        // Add Xcode DerivedData (fixed location)
        let derivedData = URL.libraryDirectory.appending(path: "Developer/Xcode/DerivedData")
        if FileManager.default.fileExists(atPath: derivedData.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: derivedData)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: derivedData,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Xcode DerivedData"
                ))
            }
        }

        // Add Xcode Archives (fixed location)
        let archives = URL.libraryDirectory.appending(path: "Developer/Xcode/Archives")
        if FileManager.default.fileExists(atPath: archives.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: archives)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: archives,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "Xcode Archives"
                ))
            }
        }

        // Add iOS Device Support (fixed location)
        let deviceSupport = URL.libraryDirectory.appending(path: "Developer/Xcode/iOS DeviceSupport")
        if FileManager.default.fileExists(atPath: deviceSupport.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: deviceSupport)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: deviceSupport,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "iOS Device Support"
                ))
            }
        }

        // Add CoreSimulator (fixed location)
        let simulators = URL.libraryDirectory.appending(path: "Developer/CoreSimulator/Devices")
        if FileManager.default.fileExists(atPath: simulators.path) {
            let size = (try? await DiskAnalyzer.directorySize(at: simulators)) ?? 0
            if size > 0 {
                items.append(CleanupItem(
                    id: UUID(),
                    path: simulators,
                    size: size,
                    type: .directory,
                    module: id,
                    moduleName: "iOS Simulators"
                ))
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

        var currentDepth = 0
        var lastPath = baseURL.path

        while let url = enumerator.nextObject() as? URL {
            // Track depth
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
                    guard checker.validate(url).isSafe else { continue }

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

        for item in items where item.module == id {
            if dryRun {
                processed += 1
                freed += item.size
            } else {
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
            let indicatorPath = parent.appending(path: indicator)
            if FileManager.default.fileExists(atPath: indicatorPath.path) {
                return true
            }
        }

        // If no indicators specified, just match the directory name
        return siblingIndicators.isEmpty
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
    ]
}

// MARK: - Project Discovery

struct ProjectInfo: Identifiable {
    let id = UUID()
    let path: URL
    let type: ProjectType
    let artifactPaths: [URL]
    var artifactSize: Int64 = 0

    var name: String {
        path.lastPathComponent
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: artifactSize, countStyle: .file)
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
}

actor ProjectScanner {
    /// Discover projects with cleanable artifacts
    func discoverProjects(in baseURL: URL, maxDepth: Int = 5) async -> [ProjectInfo] {
        var projects: [ProjectInfo] = []

        let projectIndicators: [(String, ProjectType, [String])] = [
            ("package.json", .nodejs, ["node_modules"]),
            ("Package.swift", .swift, [".build"]),
            ("Cargo.toml", .rust, ["target"]),
            ("requirements.txt", .python, [".venv", "venv", "__pycache__"]),
            ("pyproject.toml", .python, [".venv", "venv", "__pycache__"]),
            ("build.gradle", .java, [".gradle", "build"]),
            ("build.gradle.kts", .java, [".gradle", "build"]),
            ("go.mod", .go, ["vendor"]),
            ("Gemfile", .ruby, [".bundle", "vendor/bundle"]),
            ("composer.json", .php, ["vendor"]),
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
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

                    for artifactDir in artifactDirs {
                        let artifactPath = projectPath.appending(path: artifactDir)
                        if FileManager.default.fileExists(atPath: artifactPath.path) {
                            artifacts.append(artifactPath)
                            totalSize += (try? await DiskAnalyzer.directorySize(at: artifactPath)) ?? 0
                        }
                    }

                    if !artifacts.isEmpty {
                        var project = ProjectInfo(
                            path: projectPath,
                            type: projectType,
                            artifactPaths: artifacts
                        )
                        project.artifactSize = totalSize
                        projects.append(project)
                    }

                    break
                }
            }
        }

        return projects.sorted { $0.artifactSize > $1.artifactSize }
    }
}
