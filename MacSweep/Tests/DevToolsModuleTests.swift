import Testing
import Foundation
@testable import MacSweepCore

final class DevToolsModuleTests {

    let testDirectory: URL

    // swift-testing creates a fresh instance per @Test: init() is the per-test
    // setUp, deinit is the per-test tearDown. Each instance gets a UUID-scoped
    // temp dir so parallel test execution can't collide. The fixtures live under
    // FileManager.temporaryDirectory (/var/folders/…) on purpose: that root is in
    // ProtectedPaths.safeCacheRoots, so SafetyChecker.validateForScan admits the
    // artifact paths and the tests exercise discovery, not the safety gate.
    init() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSweepTests-\(UUID().uuidString)")

        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: testDirectory)
    }

    // MARK: - Fixture Helpers

    /// Create a project directory containing the given indicator entries (files
    /// unless the name looks like a bundle/package directory) and artifact
    /// directories, each seeded with one small file so they exist on disk.
    private func makeProject(
        named name: String,
        indicators: [String],
        artifactDirectories: [String]
    ) throws -> URL {
        let projectDir = testDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        for indicator in indicators {
            let indicatorURL = projectDir.appendingPathComponent(indicator)
            if indicator.hasSuffix(".xcodeproj") || indicator.hasSuffix(".xcworkspace") {
                try FileManager.default.createDirectory(at: indicatorURL, withIntermediateDirectories: true)
            } else {
                try Data("fixture".utf8).write(to: indicatorURL)
            }
        }

        for artifactDir in artifactDirectories {
            let dirURL = projectDir.appendingPathComponent(artifactDir)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try Data(repeating: 0, count: 128).write(to: dirURL.appendingPathComponent("artifact.bin"))
        }

        return projectDir
    }

    private func discoveredProjects() async -> [ProjectInfo] {
        await ProjectScanner().discoverProjects(in: testDirectory)
    }

    /// Symlink-resolved path for URL comparison: the fixture URLs are built from
    /// `temporaryDirectory` (`/var/folders/…`) while the scanner's enumerator
    /// yields the resolved `/private/var/folders/…` form.
    private func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    // MARK: - Project Discovery: existing types (regression guard)

    @Test func discoverProjectsDetectsNodeProject() async throws {
        let projectDir = try makeProject(
            named: "node-app",
            indicators: ["package.json"],
            artifactDirectories: ["node_modules", "dist"]
        )

        let projects = await discoveredProjects()

        let project = try #require(projects.first { canonicalPath($0.path) == canonicalPath(projectDir) })
        #expect(project.type == .nodejs)
        let artifactNames = Set(project.artifactPaths.map(\.lastPathComponent))
        #expect(artifactNames.contains("node_modules"))
        #expect(artifactNames.contains("dist"))
    }

    @Test func projectDiscoveryDepthMatchesDevToolsScan() {
        #expect(ProjectScanner.defaultMaxDepth == DevToolsModule.defaultMaxDepth)
    }

    @Test func discoverProjectsDetectsSwiftProject() async throws {
        let projectDir = try makeProject(
            named: "swift-pkg",
            indicators: ["Package.swift"],
            artifactDirectories: [".build"]
        )

        let projects = await discoveredProjects()

        let project = try #require(projects.first { canonicalPath($0.path) == canonicalPath(projectDir) })
        #expect(project.type == .swift)
        #expect(project.artifactPaths.map(\.lastPathComponent) == [".build"])
    }

    // MARK: - Project Discovery: types missing from the browser table (#112)

    @Test func discoverProjectsDetectsCocoaPodsProject() async throws {
        let projectDir = try makeProject(
            named: "pods-app",
            indicators: ["Podfile"],
            artifactDirectories: ["Pods"]
        )

        let projects = await discoveredProjects()

        let project = try #require(projects.first { canonicalPath($0.path) == canonicalPath(projectDir) })
        #expect(project.type == .xcode)
        #expect(project.artifactPaths.map(\.lastPathComponent).contains("Pods"))
    }

    @Test func discoverProjectsDetectsXcodeProject() async throws {
        let projectDir = try makeProject(
            named: "xcode-app",
            indicators: ["App.xcodeproj"],
            artifactDirectories: ["build"]
        )

        let projects = await discoveredProjects()

        let project = try #require(projects.first { canonicalPath($0.path) == canonicalPath(projectDir) })
        #expect(project.type == .xcode)
        #expect(project.artifactPaths.map(\.lastPathComponent).contains("build"))
    }

    @Test func discoverProjectsDetectsDotNetProject() async throws {
        let projectDir = try makeProject(
            named: "dotnet-app",
            indicators: ["App.csproj"],
            artifactDirectories: ["bin", "obj"]
        )

        let projects = await discoveredProjects()

        let project = try #require(projects.first { canonicalPath($0.path) == canonicalPath(projectDir) })
        #expect(project.type == .dotnet)
        let artifactNames = Set(project.artifactPaths.map(\.lastPathComponent))
        #expect(artifactNames.contains("bin"))
        #expect(artifactNames.contains("obj"))
    }

    @Test func discoverProjectsDetectsCMakeProject() async throws {
        let projectDir = try makeProject(
            named: "cmake-app",
            indicators: ["CMakeLists.txt"],
            artifactDirectories: ["build"]
        )

        let projects = await discoveredProjects()

        let project = try #require(projects.first { canonicalPath($0.path) == canonicalPath(projectDir) })
        #expect(project.type == .cmake)
        #expect(project.artifactPaths.map(\.lastPathComponent).contains("build"))
    }

    /// A CocoaPods project always carries both a Podfile and an .xcodeproj —
    /// the two indicators must resolve to ONE project entry, not a duplicate
    /// per indicator file.
    @Test func discoverProjectsDeduplicatesIndicatorsOfSameType() async throws {
        let projectDir = try makeProject(
            named: "pods-xcode-app",
            indicators: ["Podfile", "App.xcodeproj"],
            artifactDirectories: ["Pods", "build"]
        )

        let projects = await discoveredProjects()

        let matches = projects.filter { canonicalPath($0.path) == canonicalPath(projectDir) }
        #expect(matches.count == 1)
        let artifactNames = Set(matches.first?.artifactPaths.map(\.lastPathComponent) ?? [])
        #expect(artifactNames.contains("Pods"))
        #expect(artifactNames.contains("build"))
    }

    /// A polyglot directory (e.g. Node + Rust) keeps one entry PER type, matching
    /// the pre-existing behavior of the hand-written indicator table.
    @Test func discoverProjectsKeepsSeparateEntriesPerType() async throws {
        let projectDir = try makeProject(
            named: "polyglot-app",
            indicators: ["package.json", "Cargo.toml"],
            artifactDirectories: ["node_modules", "target"]
        )

        let projects = await discoveredProjects()

        let types = Set(projects.filter { canonicalPath($0.path) == canonicalPath(projectDir) }.map(\.type))
        #expect(types == [.nodejs, .rust])
    }

    // MARK: - Safety gate (#112: discoverProjects must apply validateForScan)

    /// An artifact path that is a symlink escaping the home directory must be
    /// rejected by the same SafetyChecker.validateForScan gate that
    /// scanForPatterns already applies — otherwise a protected path becomes
    /// listable/selectable in the per-project browser UI.
    @Test func discoverProjectsExcludesArtifactSymlinksPointingOutsideHome() async throws {
        let projectDir = testDirectory.appendingPathComponent("escaping-app")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: projectDir.appendingPathComponent("package.json"))

        // node_modules -> /System/Library: exists on every macOS host, and
        // validateForScan refuses symlinks that point outside home.
        try FileManager.default.createSymbolicLink(
            at: projectDir.appendingPathComponent("node_modules"),
            withDestinationURL: URL(fileURLWithPath: "/System/Library")
        )

        let projects = await discoveredProjects()

        // The only artifact is unsafe, so the project must not surface at all.
        #expect(!projects.contains { canonicalPath($0.path) == canonicalPath(projectDir) })
    }
}
