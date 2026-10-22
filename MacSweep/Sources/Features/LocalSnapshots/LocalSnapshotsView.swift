import SwiftUI

struct LocalSnapshotsView: View {
    @State private var inventory = LocalSnapshotInventory()
    @State private var target = LocalSnapshotThinningTarget.oneGiB
    @State private var scanning = false
    @State private var showingReview = false
    @State private var message: String?
    private let service = LocalSnapshotService()
    private let isSnapshot: Bool

    init(snapshotInventory: LocalSnapshotInventory? = nil) {
        isSnapshot = snapshotInventory != nil
        _inventory = State(initialValue: snapshotInventory ?? LocalSnapshotInventory())
    }

    var body: some View {
        FeaturePageShell(title: "Local Snapshots", subtitle: "Time Machine restore points on this Mac") {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        explanation
                        capacitySummary
                        if let blocker = inventory.permissions.blocker {
                            Label(blocker, systemImage: "lock.shield").foregroundStyle(.orange)
                            if !inventory.permissions.hasFullDiskAccess {
                                Button("Open Full Disk Access Settings") { FullDiskAccess.openSystemPreferences() }
                            }
                        }
                        if inventory.isBackupRunning == true {
                            Text("A Time Machine backup is running. Thinning remains disabled until it finishes.")
                                .foregroundStyle(.orange)
                        }
                        if !inventory.issues.isEmpty {
                            Text(inventory.issues.joined(separator: "\n"))
                                .foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if let message { Text(message).textSelection(.enabled) }
                        snapshotList
                        controls
                    }
                    .padding()
                }
                if scanning { ProgressView("Reading local snapshots…").padding() }
            }
        }
        .task { if !isSnapshot { await refresh() } }
        .cleanupReview(
            isPresented: $showingReview, items: [], disposition: .toolNative("Time Machine thinning on /"),
            note: reviewNote, additionalCount: inventory.snapshots.count, additionalBytes: nil,
            additionalModules: ["Local Time Machine Snapshots"],
            additionalPaths: [URL(fileURLWithPath: "/")], onConfirm: thin)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local snapshots let Time Machine restore previous files while your backup disk is disconnected.")
            Text("macOS normally removes snapshots as they age or space is needed. You can usually leave them alone.")
            Text("Thinning can remove local restore points. It cannot be undone and may reclaim less than requested.")
                .foregroundStyle(.orange)
            Text(
                "MacSweep requests administrator authorization after review. Full Disk Access must already be granted.")
            Text("Only local snapshots on the startup volume are requested. Backup disks and schedules are unchanged.")
        }
        .font(.callout)
    }

    private var capacitySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volume capacity").font(.headline)
            Text("Available now: \(availableText)")
            Text(
                "Additional reclaimable capacity estimate: \(reclaimableText)"
            )
            Text(
                "This estimate includes all macOS reclaimable sources. "
                    + "Per-snapshot and total snapshot sizes are unknown."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding().macSweepCard()
    }

    private var availableText: String {
        inventory.capacity?.available.availableBytes?.formattedFileSize ?? "Unavailable"
    }
    private var reclaimableText: String {
        inventory.capacity?.reclaimableEstimate?.formattedFileSize ?? "Unavailable"
    }

    private var snapshotList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(inventory.snapshots.count) local restore points").font(.headline)
            if inventory.snapshots.isEmpty {
                Text(
                    inventory.nativeSupported
                        ? "No local Time Machine snapshots were found. Snapshots depend on Time Machine and APFS."
                        : "A complete snapshot inventory is unavailable. Details are shown above."
                )
                .foregroundStyle(.secondary)
            }
            ForEach(inventory.snapshots) { snapshot in
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                    VStack(alignment: .leading) {
                        Text(snapshot.dateToken).font(.system(.body, design: .monospaced))
                        Text(snapshot.isDataless ? "Dataless snapshot · size unavailable" : "Size unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Review only").font(.caption).foregroundStyle(.secondary)
                }
                .padding().macSweepCard()
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Requested thinning", selection: $target) {
                ForEach(LocalSnapshotThinningTarget.allCases) { choice in Text(choice.title).tag(choice) }
            }
            Text(target.commandDescription).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Urgency 1 · administrator authorization · startup volume / · native best effort")
                .font(.caption).foregroundStyle(.secondary)
            if let blocker = service.requestBlocker(target) { Text(blocker).foregroundStyle(.orange) }
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(scanning || isSnapshot)
                Spacer()
                Button("Review Thinning…") { showingReview = true }
                    .disabled(scanning || !inventory.canThin || service.requestBlocker(target) != nil || isSnapshot)
            }
        }
    }

    private var reviewNote: String {
        "Administrator authorization will be requested for: \(target.commandDescription). "
            + "Time Machine chooses which local restore points to remove. This can reduce recovery options "
            + "and cannot be undone. Snapshots created during authorization may also be included. "
            + "Requested bytes are a goal, not an upper bound on snapshot data removed. "
            + "Snapshot sizes and causally reclaimed bytes are unknown. Observed volume changes include other apps."
    }

    private func refresh() async {
        scanning = true
        defer { scanning = false }
        inventory = await service.scan()
    }

    private func thin() async -> CleanupResult? {
        let receipt = await service.thin(target, reviewed: inventory, confirmed: true)
        if let observation = receipt.observation, let change = observation.observedAvailableChange {
            message =
                "Observed available-space change: \(change >= 0 ? "+" : "−")\(change.magnitude.formatted()) bytes. "
                + "This includes other activity; bytes reclaimed specifically by snapshots are unknown."
        } else {
            message = "Available-space change could not be measured. Snapshot-attributed reclaimed bytes are unknown."
        }
        if let before = receipt.beforeReclaimable, let after = receipt.afterReclaimable {
            message =
                (message ?? "") + " Reclaimable estimate: \(before.formattedFileSize) → \(after.formattedFileSize)."
        }
        if !receipt.errors.isEmpty { message = receipt.errors.joined(separator: "\n") + "\n" + (message ?? "") }
        await refresh()
        return receipt.result
    }
}
