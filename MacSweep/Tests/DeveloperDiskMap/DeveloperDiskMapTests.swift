import Darwin
import Foundation
import Testing

@testable import MacSweepCore

private actor MapProgressProbe {
    var updates: [DiskMapReport] = []
    func append(_ report: DiskMapReport) { updates.append(report) }
}

final class DeveloperDiskMapTests {
    private let temporary: TempTestDirectory
    private let home: URL

    init() throws {
        temporary = try TempTestDirectory(prefix: "DeveloperDiskMap")
        home = temporary.url.resolvingSymlinksInPath()
    }

    private func write(_ path: String, bytes: Int = 8192) throws -> URL {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private func service(_ roots: [DiskMapRoot], projects: [URL] = []) -> DeveloperDiskMapService {
        var service = DeveloperDiskMapService()
        service.home = home
        service.knownRoots = roots
        service.projectRoots = projects
        service.cache = DiskMapCache()
        service.checker = { SafetyChecker(userRules: .empty) }
        service.freeBytes = { nil }
        return service
    }

    @Test func repositoryPartitionsIncludeNestedGeneratedArtifactsWithoutDoubleCounting() async throws {
        let source = try write("Projects/App/Sources/main.swift", bytes: 1200)
        _ = try write("Projects/App/Packages/web/node_modules/pkg/index.js", bytes: 7300)
        _ = try write("Projects/App/Packages/native/.build/object", bytes: 4100)
        _ = try write("Projects/App/.git/HEAD", bytes: 25)
        let report = await service([], projects: [home.appending(path: "Projects")]).scan()
        let repository = try #require(report.roots.first)
        #expect(repository.kind == .repository && repository.logicalBytes == 12_625)
        #expect(repository.children.count == 2)
        let generated = try #require(repository.children.first { $0.kind == .generated })
        let sourceGroup = try #require(repository.children.first { $0.kind == .source })
        #expect(generated.logicalBytes == 11_400 && sourceGroup.logicalBytes == 1225)
        #expect(generated.allocatedBytes + sourceGroup.allocatedBytes == repository.allocatedBytes)
        #expect(sourceGroup.find(source.path + "#source")?.name == "main.swift")
        #expect(!sourceGroup.canOpenOwner && generated.canOpenOwner)
    }

    @Test func knownRootsPublishBeforeProjectDiscoveryAndNeverStartHomeSizing() async throws {
        _ = try write("Cache/blob", bytes: 2048)
        _ = try write("Other/private-data", bytes: 7000)
        let progress = MapProgressProbe()
        let report = await service([
            DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache, owner: .packageManagers)
        ])
        .scan { await progress.append($0) }
        #expect(report.finished && !report.fullHome && report.roots.count == 1)
        #expect(report.grouped.logicalBytes == 2048)
        let updates = await progress.updates
        #expect(updates.contains { !$0.finished && !$0.roots.isEmpty })
    }

    @Test func optionalHomeExcludesMeasuredRootsAndHardLinksAcrossRoots() async throws {
        let first = try write("Cache/blob", bytes: 5555)
        _ = try write("Other/file", bytes: 2345)
        try FileManager.default.linkItem(at: first, to: home.appending(path: "Other/linked"))
        let roots = [DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache, owner: .packageManagers)]
        let report = await service(roots).scan(fullHome: true)
        #expect(report.fullHome && report.grouped.logicalBytes == 7900)
        #expect(report.roots.count == 2)
        let diskTree = report.grouped.diskNode()
        #expect(diskTree.size == report.grouped.allocatedBytes)
        #expect(diskTree.children.reduce(0) { $0 + $1.size } == diskTree.size)
    }

    @Test func permissionFailurePreservesUsefulMeasurementsAndMarksUnknownPaths() async throws {
        _ = try write("Cache/good/file", bytes: 1234)
        _ = try write("Cache/blocked/file", bytes: 9000)
        var scanner = service([DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache)])
        scanner.beforeRead = { path in if path.lastPathComponent == "blocked" { throw POSIXError(.EACCES) } }
        let report = await scanner.scan()
        let root = try #require(report.roots.first)
        #expect(root.logicalBytes == 1234 && root.coverage == .partial)
        #expect(root.children.first { $0.name == "blocked" }?.coverage == .unknown)
        #expect(!report.issues.isEmpty && root.sizeLabel.hasPrefix("At least"))
    }

    @Test func userProtectionAndSymlinksRemainVisibleWithoutOwningActions() async throws {
        _ = try write("Cache/retained/file", bytes: 3000)
        _ = try write("Cache/visible", bytes: 1000)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: "Cache/link"),
            withDestinationURL: home.appending(path: "Cache/retained"))
        var scanner = service([DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache, owner: .packageManagers)])
        let fixtureHome = home
        scanner.checker = {
            SafetyChecker(
                userRules: UserProtectionRules(
                    ignoreContents: "", protectContents: "Cache/retained", homeURL: fixtureHome))
        }
        let report = await scanner.scan()
        let root = try #require(report.roots.first)
        #expect(root.logicalBytes == 1000 && root.coverage == .partial)
        #expect(report.grouped.coverage == .partial)
        let protected = try #require(root.children.first { $0.name == "retained" })
        #expect(protected.protectedReason != nil && !protected.canOpenOwner && protected.children.isEmpty)
        #expect(root.children.first { $0.name == "link" }?.coverage == .unknown)
    }

    @Test func boundedEntriesAndDepthProduceLowerBoundsWithoutDroppingCompletedFiles() throws {
        for index in 0..<30 { _ = try write("Cache/\(index)", bytes: 100) }
        var measurement = DiskMapMeasurement(checker: SafetyChecker(userRules: .empty))
        measurement.limits.maximumEntries = 8
        let result = try measurement.measure(DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache))
        #expect(result.node.coverage == .partial && result.node.logicalBytes == 700)
        #expect(!result.issues.isEmpty)
        measurement.limits.maximumEntries = 100
        measurement.limits.seconds = 0
        let timed = try measurement.measure(DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache))
        #expect(timed.node.coverage == .partial && timed.node.logicalBytes == 0)
        measurement.limits.seconds = 1
        measurement.limits.maximumDepth = 0
        let shallow = try measurement.measure(DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache))
        #expect(shallow.node.coverage == .partial && shallow.node.logicalBytes == 0)
    }

    @Test func resumeAdvancesPastPartialRootsAndHomeScanReusesKnownMeasurements() async throws {
        _ = try write("First/one", bytes: 100)
        _ = try write("First/two", bytes: 100)
        _ = try write("Second/file", bytes: 200)
        var scanner = service([
            DiskMapRoot(url: home.appending(path: "First"), kind: .cache),
            DiskMapRoot(url: home.appending(path: "Second"), kind: .toolchain)
        ])
        scanner.limits.maximumEntries = 2
        let initialScanner = scanner
        let task = Task {
            await initialScanner.scan { report in
                if report.roots.count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let partial = await task.value
        #expect(!partial.finished && partial.roots.first?.coverage == .partial)
        scanner.beforeRead = { path in
            if path.lastPathComponent == "First" { throw POSIXError(.EACCES) }
        }
        let resumed = await scanner.scan()
        #expect(resumed.finished && resumed.roots.count == 2 && resumed.cached)
        #expect(resumed.roots.first?.logicalBytes == 100 && resumed.grouped.logicalBytes == 300)
        let homeScan = await scanner.scan(fullHome: true)
        #expect(homeScan.cached && homeScan.roots.first?.logicalBytes == 100)
        #expect(homeScan.grouped.coverage == .partial)
    }

    @Test func cancelledCallerCannotPublishAnApparentlyCompleteCachedScan() async throws {
        _ = try write("Cache/file", bytes: 100)
        let scanner = service([DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache)])
        #expect(await scanner.scan().finished)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await scanner.scan()
        }
        let cancelled = await task.value
        #expect(!cancelled.finished && !cancelled.cached && !cancelled.issues.isEmpty)
    }

    @Test func overallAndRootBudgetsCannotClaimCompleteCoverage() async throws {
        _ = try write("First/file", bytes: 100)
        _ = try write("Second/file", bytes: 200)
        var scanner = service([
            DiskMapRoot(url: home.appending(path: "First"), kind: .cache),
            DiskMapRoot(url: home.appending(path: "Second"), kind: .cache)
        ])
        scanner.limits.maximumScanSeconds = 0
        let stopped = await scanner.scan()
        #expect(!stopped.finished && stopped.roots.isEmpty && !stopped.issues.isEmpty)
        scanner.limits.maximumScanSeconds = 10
        scanner.limits.maximumRoots = 1
        let bounded = await scanner.scan()
        #expect(!bounded.finished && bounded.roots.count == 1)
        #expect(bounded.issues.contains { $0.contains("root-count") })
    }

    @Test func overlapEliminationUsesComponentBoundaries() {
        let roots = ["Cache", "Cache/nested", "CacheOther"].map {
            DiskMapRoot(url: home.appending(path: $0), kind: .cache)
        }
        #expect(DiskMapRoots.disjoint(roots).count == 2)
        #expect(!DiskMapRoots.contains(home.appending(path: "Cache"), home.appending(path: "CacheOther")))
        let swap = DiskMapNode(id: "swap", name: "Swap", kind: .swap, owner: .virtualMachines)
        #expect(!swap.canOpenOwner)
    }

    @Test func cacheTTLPreventsRepeatedWalkAndRefreshSeesChanges() async throws {
        _ = try write("Cache/blob", bytes: 1000)
        let scanner = service([DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache)])
        let first = await scanner.scan()
        _ = try write("Cache/new", bytes: 2000)
        let cached = await scanner.scan()
        #expect(cached.cached && cached.grouped.logicalBytes == first.grouped.logicalBytes)
        let refreshed = await scanner.scan(refresh: true)
        #expect(!refreshed.cached && refreshed.grouped.logicalBytes == 3000)
    }

    @Test func changedProtectionRulesInvalidateEvenCollapsedCachedDescendants() async throws {
        _ = try write("Cache/deep/child/hidden/file", bytes: 1000)
        var scanner = service([DiskMapRoot(url: home.appending(path: "Cache"), kind: .cache, owner: .packageManagers)])
        scanner.limits.visibleDepth = 1
        #expect(await scanner.scan().grouped.logicalBytes == 1000)
        let fixtureHome = home
        scanner.checker = {
            SafetyChecker(
                userRules: UserProtectionRules(
                    ignoreContents: "", protectContents: "Cache/deep/child/hidden", homeURL: fixtureHome))
        }
        let protected = await scanner.scan()
        #expect(!protected.cached && protected.grouped.logicalBytes == 0)
        #expect(protected.roots.first?.coverage == .partial)
    }

    @Test func cancelledScanRetainsCompletedRootsAndResumeReusesThem() async throws {
        _ = try write("First/file", bytes: 1000)
        _ = try write("Second/file", bytes: 2000)
        let scanner = service([
            DiskMapRoot(url: home.appending(path: "First"), kind: .cache),
            DiskMapRoot(url: home.appending(path: "Second"), kind: .toolchain)
        ])
        let task = Task {
            await scanner.scan { report in
                if report.roots.count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let cancelled = await task.value
        #expect(!cancelled.finished && cancelled.roots.count == 1 && !cancelled.issues.isEmpty)
        let resumed = await scanner.scan()
        #expect(resumed.finished && resumed.grouped.logicalBytes == 3000)
    }
}
