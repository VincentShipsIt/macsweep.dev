import Foundation

enum VirtualMachineManager: String, CaseIterable, Identifiable, Sendable {
    case orbStack, colima, lima, utm, parallels, virtualBox, vagrant, docker, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orbStack: return "OrbStack"
        case .colima: return "Colima"
        case .lima: return "Lima"
        case .utm: return "UTM"
        case .parallels: return "Parallels"
        case .virtualBox: return "VirtualBox"
        case .vagrant: return "Vagrant Boxes"
        case .docker: return "Docker"
        case .claude: return "Claude Cowork & Environments"
        }
    }
    var executableName: String? {
        switch self {
        case .orbStack: return "orb"
        case .colima: return "colima"
        case .lima: return "limactl"
        case .utm: return "utmctl"
        case .parallels: return "prlctl"
        case .virtualBox: return "VBoxManage"
        case .vagrant: return "vagrant"
        case .docker: return "docker"
        case .claude: return nil
        }
    }
    var retentionReason: String {
        switch self {
        case .lima:
            return
                "Native deletion requires verified stopped, unprotected VZ state and exclusive default-home ownership."
        case .colima: return "Colima teardown can stop its VM; non-stopping automatic removal is unsupported."
        case .orbStack:
            return "OrbStack deletion's stopped-only refusal and shared-disk ownership are unverified; use OrbStack."
        case .utm:
            return "UTM native deletion's stopped-only refusal and external-drive ownership are unverified; use UTM."
        case .parallels:
            return
                "Parallels deletion is permanent; stopped-only refusal and exclusive disk ownership are unverified."
        case .virtualBox:
            return
                "VBoxManage can delete attached external media; exclusive media ownership is unverified."
        case .vagrant:
            return "Vagrant's cached environment index cannot prove complete box references; no broad or forced prune."
        case .docker: return "Persistent Docker VM disk; use separately reviewed Docker resource actions."
        case .claude:
            return
                "Persistent app-owned environment, session state and VM downloads are retained; not disposable cache."
        }
    }
}

struct VirtualMachineTarget: Identifiable, Sendable {
    let id: String
    let manager: VirtualMachineManager
    let name: String
    var paths: [URL]
    var status: String
    var measuredBytes: Int64?
    var virtualCapacity: Int64?
    var modified: Date?
    var lastUsed: Date?
    var retentionReason: String?
    var evidence: VirtualMachineEvidence?
    let nativeSignature: String?
    let nativeName: String?
    let persistentState: Bool
    var canRemove: Bool {
        manager == .lima && retentionReason == nil && measuredBytes != nil && evidence != nil && nativeName != nil
    }
}

struct VirtualMachineEvidence: Equatable, Sendable {
    let roots: [DevArtifactIdentity]
    let nodes: [DevArtifactNode]
    let executablePath: String
    let executableIdentity: DevArtifactIdentity
    let executableStamp: DevArtifactNode
    let ownerUID: UInt32
}

struct VirtualMachineInventory: Sendable {
    var targets: [VirtualMachineTarget] = []
    var installedManagers: Set<VirtualMachineManager> = []
    var issues: [String] = []
    var executablePaths: [VirtualMachineManager: String] = [:]
    var completeManagers: Set<VirtualMachineManager> = []
    var managerVersions: [VirtualMachineManager: String] = [:]
}

struct VirtualMachineReceipt: Sendable {
    let removedIDs: [String]
    let processedTargetBytes: Int64
    let errors: [String]
    let observation: VolumeSpaceObservation?
    var result: CleanupResult {
        CleanupResult(
            itemsProcessed: removedIDs.count, bytesFreed: processedTargetBytes,
            errors: errors.map { CleanupError(path: URL(fileURLWithPath: "/"), message: $0) },
            accounting: CleanupAccounting(
                estimatedTargetBytes: processedTargetBytes,
                estimatedProcessedBytes: processedTargetBytes,
                movedToTrashBytes: 0, permanentlyRemovedTargetBytes: 0,
                removedLocalCopyBytes: 0, toolProcessedBytes: processedTargetBytes,
                volumeObservations: observation.map { [$0] } ?? []))
    }
}

struct VirtualMachineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

typealias VirtualMachineCommand = @Sendable (String, [String], TimeInterval) async throws -> ProcessResult
