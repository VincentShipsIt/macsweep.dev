import AppKit
import SwiftUI

struct VirtualMachinesView: View {
    @State private var inventory = VirtualMachineInventory()
    @State private var selected: Set<String> = []
    @State private var scanning = false
    @State private var showingReview = false
    @State private var message: String?
    private let isSnapshot: Bool
    private let onReviewDocker: (() -> Void)?
    private let service = VirtualMachineService()

    init(snapshotInventory: VirtualMachineInventory? = nil, onReviewDocker: (() -> Void)? = nil) {
        isSnapshot = snapshotInventory != nil
        self.onReviewDocker = onReviewDocker
        _inventory = State(initialValue: snapshotInventory ?? VirtualMachineInventory())
    }

    var body: some View {
        FeaturePageShell(
            title: "VMs & Containers", subtitle: "Persistent virtual disks and environments; manual review only"
        ) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        explanation
                        if let message { Text(message).foregroundStyle(.orange).textSelection(.enabled) }
                        if !inventory.issues.isEmpty {
                            Text(inventory.issues.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if inventory.installedManagers.isEmpty {
                            ContentUnavailableView(
                                "No VM Storage Found", systemImage: "desktopcomputer",
                                description: Text("No supported local runtimes or owned VM stores were found."))
                        }
                        ForEach(visibleManagers) { manager in
                            managerSection(manager)
                        }
                    }
                    .padding()
                }
                footer
            }
        }
        .task { if !isSnapshot { await refresh() } }
        .cleanupReview(
            isPresented: $showingReview, items: [], disposition: .toolNative("Exact stopped Lima VM removal"),
            note: reviewNote, additionalCount: selectedTargets.count, additionalBytes: selectedBytes,
            additionalModules: ["Virtual Machines"], additionalPaths: selectedTargets.flatMap(\.paths),
            onConfirm: remove)
    }

    private var visibleManagers: [VirtualMachineManager] {
        VirtualMachineManager.allCases.filter { inventory.installedManagers.contains($0) }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(
                "VM disks contain persistent operating systems, environments and user data. "
                    + "They are not disposable caches."
            )
            Text(
                "Removing a VM can permanently lose its files and require setup or downloads again. "
                    + "Nothing is selected automatically."
            )
            Text(
                "Host swap is separate from VM disk storage. "
                    + "MacSweep never deletes live swap or stops a VM during cleanup."
            )
            Text(
                "Allocated storage shown covers only the listed paths. "
                    + "Virtual capacity is a guest limit, not disk space used."
            )
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var selectedTargets: [VirtualMachineTarget] {
        inventory.targets.filter { selected.contains($0.id) && $0.canRemove }
    }
    private var selectedBytes: Int64 {
        selectedTargets.compactMap(\.measuredBytes).reduce(0) { total, bytes in
            let (next, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? Int64.max : next
        }
    }
    private var reviewNote: String {
        selectedTargets.compactMap { target in
            target.nativeName.map { "limactl --tty=false delete \($0)" }
        }.joined(separator: "\n")
            + "\nThis permanently removes persistent VM state. It cannot be restored from Trash. "
            + "Only the exact reviewed, stopped and unprotected machines qualify. Native target sizes are estimates; "
            + "volume changes include other activity and do not prove causally freed bytes."
    }

    private func managerSection(_ manager: VirtualMachineManager) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(manager.title).font(.headline)
                Spacer()
                if manager == .docker, let onReviewDocker {
                    Button("Review Docker Resources…", action: onReviewDocker)
                }
            }
            let targets = inventory.targets.filter { $0.manager == manager }
            if targets.isEmpty {
                Text("Runtime detected; no owned local VM records were verified. Diagnostics remain visible above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(targets) { target in
                VirtualMachineRow(target: target, selected: selected.contains(target.id)) {
                    if selected.contains(target.id) { selected.remove(target.id) } else { selected.insert(target.id) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if scanning { ProgressView().controlSize(.small) }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(scanning || isSnapshot)
            Text("\(selectedTargets.count) selected · \(selectedBytes.formattedFileSize) estimated scope")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Review Removal…") { showingReview = true }
                .disabled(scanning || selectedTargets.isEmpty || isSnapshot)
        }
        .padding()
    }

    private func refresh() async {
        scanning = true
        selected = []
        defer { scanning = false }
        inventory = await service.scan()
    }
    private func remove() async -> CleanupResult? {
        let receipt = await service.remove(selectedTargets, confirmed: true)
        message = receipt.errors.isEmpty ? nil : receipt.errors.joined(separator: "\n")
        await refresh()
        return receipt.result
    }
}

private struct VirtualMachineRow: View {
    let target: VirtualMachineTarget
    let selected: Bool
    let toggle: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(target.name, isOn: Binding(get: { selected }, set: { _ in toggle() }))
                .labelsHidden().disabled(!target.canRemove)
                .accessibilityLabel("Select \(target.name)")
            VStack(alignment: .leading, spacing: 5) {
                Label(target.name, systemImage: target.canRemove ? "desktopcomputer" : "lock.shield")
                    .fontWeight(.medium)
                Text("\(target.status) · persistent state · last use \(target.lastUsed?.formatted() ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(target.paths, id: \.path) { path in
                    Text(path.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Text(target.retentionReason ?? "Review required: permanent native deletion of this stopped VM.")
                    .font(.caption).foregroundStyle(target.canRemove ? Color.secondary : Color.orange)
                if let modified = target.modified {
                    Text("Modified: \(modified.formatted()) (not proof of last use)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Allocated scope: \(target.measuredBytes?.formattedFileSize ?? "unavailable")")
                    .font(.caption)
                if let capacity = target.virtualCapacity {
                    Text("Configured virtual capacity: \(capacity.formattedFileSize)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let path = target.paths.first {
                Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                    .labelStyle(.iconOnly).help("Reveal VM storage in Finder")
            }
        }
        .padding().macSweepCard()
    }
}
