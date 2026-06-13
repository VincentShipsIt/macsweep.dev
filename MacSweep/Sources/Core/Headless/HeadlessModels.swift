import Foundation

public enum HeadlessPermissionKind: String, Codable, Sendable {
    case fullDiskAccess
}

public struct HeadlessPermissionRequirement: Codable, Sendable {
    public let kind: HeadlessPermissionKind
    public let granted: Bool

    public init(kind: HeadlessPermissionKind, granted: Bool) {
        self.kind = kind
        self.granted = granted
    }
}

public struct HeadlessModulePermissionStatus: Codable, Sendable {
    public let moduleID: String
    public let moduleName: String
    public let requirements: [HeadlessPermissionRequirement]
    public let allRequirementsSatisfied: Bool

    public init(
        moduleID: String,
        moduleName: String,
        requirements: [HeadlessPermissionRequirement],
        allRequirementsSatisfied: Bool
    ) {
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.requirements = requirements
        self.allRequirementsSatisfied = allRequirementsSatisfied
    }
}

public struct HeadlessPermissionStatusReport: Codable, Sendable {
    public let fullDiskAccessGranted: Bool
    public let modules: [HeadlessModulePermissionStatus]

    public init(fullDiskAccessGranted: Bool, modules: [HeadlessModulePermissionStatus]) {
        self.fullDiskAccessGranted = fullDiskAccessGranted
        self.modules = modules
    }
}

public struct HeadlessModuleDescriptor: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let requiredPermissions: [HeadlessPermissionKind]

    public init(id: String, name: String, description: String, requiredPermissions: [HeadlessPermissionKind]) {
        self.id = id
        self.name = name
        self.description = description
        self.requiredPermissions = requiredPermissions
    }
}

public struct HeadlessCleanupError: Codable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public struct HeadlessFinding: Codable, Sendable {
    public let id: String
    public let module: String
    public let moduleName: String
    public let path: String
    public let size: Int64
    public let type: String
    public let lastModified: Date?
    public let recommended: Bool

    public init(
        id: String,
        module: String,
        moduleName: String,
        path: String,
        size: Int64,
        type: String,
        lastModified: Date?,
        recommended: Bool
    ) {
        self.id = id
        self.module = module
        self.moduleName = moduleName
        self.path = path
        self.size = size
        self.type = type
        self.lastModified = lastModified
        self.recommended = recommended
    }
}

public struct HeadlessSummary: Codable, Sendable {
    public let score: Int
    public let reclaimableBytes: Int64
    public let totalFindings: Int
    public let issueCount: Int
    public let categoryCount: Int
    public let recommendedFindings: Int
    public let recommendedBytes: Int64
    public let errors: [HeadlessCleanupError]

    public init(
        score: Int,
        reclaimableBytes: Int64,
        totalFindings: Int,
        issueCount: Int,
        categoryCount: Int,
        recommendedFindings: Int,
        recommendedBytes: Int64,
        errors: [HeadlessCleanupError]
    ) {
        self.score = score
        self.reclaimableBytes = reclaimableBytes
        self.totalFindings = totalFindings
        self.issueCount = issueCount
        self.categoryCount = categoryCount
        self.recommendedFindings = recommendedFindings
        self.recommendedBytes = recommendedBytes
        self.errors = errors
    }
}

public struct HeadlessScanResult: Codable, Sendable {
    public let executedModules: [String]
    public let permissions: HeadlessPermissionStatusReport
    public let findings: [HeadlessFinding]
    public let summary: HeadlessSummary

    public init(
        executedModules: [String],
        permissions: HeadlessPermissionStatusReport,
        findings: [HeadlessFinding],
        summary: HeadlessSummary
    ) {
        self.executedModules = executedModules
        self.permissions = permissions
        self.findings = findings
        self.summary = summary
    }
}

public struct HeadlessCleanupResult: Codable, Sendable {
    public let dryRun: Bool
    public let itemsProcessed: Int
    public let bytesFreed: Int64
    public let errors: [HeadlessCleanupError]

    public init(
        dryRun: Bool,
        itemsProcessed: Int,
        bytesFreed: Int64,
        errors: [HeadlessCleanupError]
    ) {
        self.dryRun = dryRun
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.errors = errors
    }
}

public struct HeadlessApplyResult: Codable, Sendable {
    public let scan: HeadlessScanResult
    public let cleanup: HeadlessCleanupResult

    public init(scan: HeadlessScanResult, cleanup: HeadlessCleanupResult) {
        self.scan = scan
        self.cleanup = cleanup
    }
}

public struct HeadlessMaintenanceActionDescriptor: Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let requiresAdmin: Bool

    public init(id: String, name: String, description: String, requiresAdmin: Bool) {
        self.id = id
        self.name = name
        self.description = description
        self.requiresAdmin = requiresAdmin
    }
}

public struct HeadlessMaintenanceRunResult: Codable, Sendable {
    public let action: HeadlessMaintenanceActionDescriptor
    public let success: Bool
    public let message: String
    public let bytesFreed: Int64

    public init(
        action: HeadlessMaintenanceActionDescriptor,
        success: Bool,
        message: String,
        bytesFreed: Int64
    ) {
        self.action = action
        self.success = success
        self.message = message
        self.bytesFreed = bytesFreed
    }
}

public struct HeadlessSelectionRequest: Sendable, Equatable {
    public let moduleIDs: [String]?
    public let smartCare: Bool

    public init(moduleIDs: [String]? = nil, smartCare: Bool = false) {
        self.moduleIDs = moduleIDs
        self.smartCare = smartCare
    }
}

public final class HeadlessPreparedCleanupPlan: @unchecked Sendable {
    public let scan: HeadlessScanResult
    public let cleanupPreview: HeadlessCleanupResult
    let selectedItems: [CleanupItem]

    init(scan: HeadlessScanResult, cleanupPreview: HeadlessCleanupResult, selectedItems: [CleanupItem]) {
        self.scan = scan
        self.cleanupPreview = cleanupPreview
        self.selectedItems = selectedItems
    }
}

// MARK: - Disk Usage

public struct HeadlessDiskUsage: Codable, Sendable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let freeBytes: Int64
    public let usedPercentage: Double
    public let freePercentage: Double

    public init(
        totalBytes: Int64,
        usedBytes: Int64,
        freeBytes: Int64,
        usedPercentage: Double,
        freePercentage: Double
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.usedPercentage = usedPercentage
        self.freePercentage = freePercentage
    }
}

// MARK: - Login Items

public enum HeadlessLoginItemKind: String, Codable, Sendable {
    case appService
    case launchAgent
    case launchDaemon
}

public struct HeadlessLoginItem: Codable, Sendable {
    public let name: String
    public let path: String
    public let kind: HeadlessLoginItemKind
    public let bundleIdentifier: String?
    public let enabled: Bool

    public init(
        name: String,
        path: String,
        kind: HeadlessLoginItemKind,
        bundleIdentifier: String?,
        enabled: Bool
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.enabled = enabled
    }
}

public struct HeadlessLoginItemsReport: Codable, Sendable {
    public let totalItems: Int
    public let items: [HeadlessLoginItem]

    public init(totalItems: Int, items: [HeadlessLoginItem]) {
        self.totalItems = totalItems
        self.items = items
    }
}

public struct HeadlessLoginItemMutationResult: Codable, Sendable {
    public let label: String
    public let plistPath: String
    public let kind: HeadlessLoginItemKind
    public let action: String   // "enable" | "disable" | "remove"
    public let enabled: Bool
    public let removed: Bool

    public init(
        label: String,
        plistPath: String,
        kind: HeadlessLoginItemKind,
        action: String,
        enabled: Bool,
        removed: Bool
    ) {
        self.label = label
        self.plistPath = plistPath
        self.kind = kind
        self.action = action
        self.enabled = enabled
        self.removed = removed
    }
}

// MARK: - Space Lens (disk tree)

public struct HeadlessDiskNode: Codable, Sendable {
    public let name: String
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    public let lastModified: Date?
    /// Number of direct children discovered (the `children` array is the full,
    /// depth-bounded set; consumers may truncate for display).
    public let childCount: Int
    public let children: [HeadlessDiskNode]

    public init(
        name: String,
        path: String,
        size: Int64,
        isDirectory: Bool,
        lastModified: Date?,
        childCount: Int,
        children: [HeadlessDiskNode]
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.lastModified = lastModified
        self.childCount = childCount
        self.children = children
    }
}

public struct HeadlessDiskTree: Codable, Sendable {
    public let rootPath: String
    public let depth: Int
    public let totalBytes: Int64
    public let root: HeadlessDiskNode

    public init(rootPath: String, depth: Int, totalBytes: Int64, root: HeadlessDiskNode) {
        self.rootPath = rootPath
        self.depth = depth
        self.totalBytes = totalBytes
        self.root = root
    }
}

// MARK: - Cache Analysis

public struct HeadlessCacheFinding: Codable, Sendable {
    public let path: String
    public let sizeText: String
    public let category: String
    public let regeneratesAutomatically: Bool
    public let source: String
    public let reason: String?

    public init(
        path: String,
        sizeText: String,
        category: String,
        regeneratesAutomatically: Bool,
        source: String,
        reason: String?
    ) {
        self.path = path
        self.sizeText = sizeText
        self.category = category
        self.regeneratesAutomatically = regeneratesAutomatically
        self.source = source
        self.reason = reason
    }
}

public struct HeadlessCacheReport: Codable, Sendable {
    public let fastScanCount: Int
    public let aiScanRequested: Bool
    public let aiScanRan: Bool
    public let totalFindings: Int
    public let findings: [HeadlessCacheFinding]
    public let errors: [String]

    public init(
        fastScanCount: Int,
        aiScanRequested: Bool,
        aiScanRan: Bool,
        totalFindings: Int,
        findings: [HeadlessCacheFinding],
        errors: [String]
    ) {
        self.fastScanCount = fastScanCount
        self.aiScanRequested = aiScanRequested
        self.aiScanRan = aiScanRan
        self.totalFindings = totalFindings
        self.findings = findings
        self.errors = errors
    }
}

// MARK: - App Uninstall

public struct HeadlessAppLeftover: Codable, Sendable {
    public let path: String
    public let size: Int64
    public let type: String

    public init(path: String, size: Int64, type: String) {
        self.path = path
        self.size = size
        self.type = type
    }
}

public struct HeadlessInstalledApp: Codable, Sendable {
    public let id: String
    public let name: String
    public let bundlePath: String
    public let version: String?
    public let bundleSize: Int64
    public let leftoverBytes: Int64
    public let leftoverCount: Int
    public let totalSize: Int64
    public let lastUsed: Date?
    public let leftovers: [HeadlessAppLeftover]

    public init(
        id: String,
        name: String,
        bundlePath: String,
        version: String?,
        bundleSize: Int64,
        leftoverBytes: Int64,
        leftoverCount: Int,
        totalSize: Int64,
        lastUsed: Date?,
        leftovers: [HeadlessAppLeftover]
    ) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.version = version
        self.bundleSize = bundleSize
        self.leftoverBytes = leftoverBytes
        self.leftoverCount = leftoverCount
        self.totalSize = totalSize
        self.lastUsed = lastUsed
        self.leftovers = leftovers
    }
}

public struct HeadlessUninstallableAppsReport: Codable, Sendable {
    public let totalApps: Int
    public let totalReclaimableBytes: Int64
    public let apps: [HeadlessInstalledApp]

    public init(totalApps: Int, totalReclaimableBytes: Int64, apps: [HeadlessInstalledApp]) {
        self.totalApps = totalApps
        self.totalReclaimableBytes = totalReclaimableBytes
        self.apps = apps
    }
}

public struct HeadlessUninstallResult: Codable, Sendable {
    public let appID: String
    public let appName: String
    public let bundlePath: String
    public let dryRun: Bool
    public let removedApp: Bool
    public let itemsProcessed: Int
    public let bytesFreed: Int64
    public let leftoversRemoved: Int
    public let leftovers: [HeadlessAppLeftover]
    public let errors: [HeadlessCleanupError]

    public init(
        appID: String,
        appName: String,
        bundlePath: String,
        dryRun: Bool,
        removedApp: Bool,
        itemsProcessed: Int,
        bytesFreed: Int64,
        leftoversRemoved: Int,
        leftovers: [HeadlessAppLeftover],
        errors: [HeadlessCleanupError]
    ) {
        self.appID = appID
        self.appName = appName
        self.bundlePath = bundlePath
        self.dryRun = dryRun
        self.removedApp = removedApp
        self.itemsProcessed = itemsProcessed
        self.bytesFreed = bytesFreed
        self.leftoversRemoved = leftoversRemoved
        self.leftovers = leftovers
        self.errors = errors
    }
}

// MARK: - Malware Scan

public struct HeadlessThreatFinding: Codable, Sendable {
    public let path: String
    public let category: String
    public let threatLevel: String
    public let description: String
    public let aiExplanation: String?
    public let remediation: String?

    public init(
        path: String,
        category: String,
        threatLevel: String,
        description: String,
        aiExplanation: String?,
        remediation: String?
    ) {
        self.path = path
        self.category = category
        self.threatLevel = threatLevel
        self.description = description
        self.aiExplanation = aiExplanation
        self.remediation = remediation
    }
}

public struct HeadlessMalwareScanReport: Codable, Sendable {
    public let scannedAt: Date
    public let totalScanned: Int
    public let isClean: Bool
    public let xprotectStatus: String
    public let aiAnalysisRequested: Bool
    public let findings: [HeadlessThreatFinding]

    public init(
        scannedAt: Date,
        totalScanned: Int,
        isClean: Bool,
        xprotectStatus: String,
        aiAnalysisRequested: Bool,
        findings: [HeadlessThreatFinding]
    ) {
        self.scannedAt = scannedAt
        self.totalScanned = totalScanned
        self.isClean = isClean
        self.xprotectStatus = xprotectStatus
        self.aiAnalysisRequested = aiAnalysisRequested
        self.findings = findings
    }
}

// MARK: - Homebrew

public struct HeadlessBrewPackage: Codable, Sendable {
    public let name: String
    public let currentVersion: String
    public let latestVersion: String

    public init(name: String, currentVersion: String, latestVersion: String) {
        self.name = name
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
    }
}

public struct HeadlessHomebrewReport: Codable, Sendable {
    public let outdatedCount: Int
    public let packages: [HeadlessBrewPackage]

    public init(outdatedCount: Int, packages: [HeadlessBrewPackage]) {
        self.outdatedCount = outdatedCount
        self.packages = packages
    }
}

public struct HeadlessHomebrewUpgradeResult: Codable, Sendable {
    public let upgraded: Bool
    public let log: String
    public let remainingOutdated: [HeadlessBrewPackage]

    public init(upgraded: Bool, log: String, remainingOutdated: [HeadlessBrewPackage]) {
        self.upgraded = upgraded
        self.log = log
        self.remainingOutdated = remainingOutdated
    }
}

// MARK: - Shred

public struct HeadlessShredResult: Codable, Sendable {
    public let path: String
    public let level: String
    public let isDirectory: Bool
    public let filesShredded: Int
    public let bytesShredded: Int64
    public let success: Bool
    public let errors: [String]

    public init(
        path: String,
        level: String,
        isDirectory: Bool,
        filesShredded: Int,
        bytesShredded: Int64,
        success: Bool,
        errors: [String]
    ) {
        self.path = path
        self.level = level
        self.isDirectory = isDirectory
        self.filesShredded = filesShredded
        self.bytesShredded = bytesShredded
        self.success = success
        self.errors = errors
    }
}

public enum HeadlessServiceError: Error, LocalizedError, Sendable {
    case conflictingSelection
    case invalidModules([String])
    case unknownMaintenanceAction(String)
    case pathNotFound(String)
    case shredRefused(String)
    case homebrewNotInstalled
    case appNotFound(String)
    case appRunning(String)
    case ambiguousAppMatch(String, [String])
    case uninstallFailed(String)
    case loginItemNotFound(String)
    case loginItemAmbiguous(String, [String])
    case loginItemMutationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conflictingSelection:
            return "Use either --modules or --smart-care, not both."
        case .invalidModules(let modules):
            return "Unknown modules: \(modules.joined(separator: ", "))."
        case .unknownMaintenanceAction(let action):
            return "Unknown maintenance action: \(action)."
        case .pathNotFound(let path):
            return "Path not found: \(path)."
        case .shredRefused(let reason):
            return "Refusing to shred: \(reason)."
        case .homebrewNotInstalled:
            return "Homebrew is not installed (no brew binary at /opt/homebrew or /usr/local)."
        case .appNotFound(let query):
            return "No installed application matched: \(query)."
        case .appRunning(let name):
            return "Quit \(name) before uninstalling it."
        case .ambiguousAppMatch(let query, let matches):
            return "Multiple apps match '\(query)': \(matches.joined(separator: ", ")). Use the exact bundle identifier."
        case .uninstallFailed(let reason):
            return "Uninstall failed: \(reason)."
        case .loginItemNotFound(let label):
            return "No login item matched: \(label). Use the exact Label from 'login-items list'."
        case .loginItemAmbiguous(let label, let paths):
            return "Multiple login item plists match '\(label)': \(paths.joined(separator: ", ")). Remove or rename the duplicate."
        case .loginItemMutationFailed(let reason):
            return "Login item update failed: \(reason)."
        }
    }
}
