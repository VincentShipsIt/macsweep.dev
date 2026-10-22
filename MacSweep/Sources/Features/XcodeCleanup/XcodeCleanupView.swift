import AppKit
import SwiftUI

struct XcodeCleanupView: View {
    @State private var inventory = XcodeCleanupInventory()
    @State private var selected: Set<String> = []
    @State private var scanning = false
    @State private var showingReview = false
    @State private var message: String?
    private let service = XcodeCleanupService()
    private let isSnapshot: Bool

    init(snapshotInventory: XcodeCleanupInventory? = nil) {
        isSnapshot = snapshotInventory != nil
        _inventory = State(initialValue: snapshotInventory ?? XcodeCleanupInventory())
    }

    var body: some View {
        FeaturePageShell(
            title: "Xcode Deep Clean", subtitle: "Review exact targets; active and uncertain data stays protected"
        ) {
            VStack(spacing: 0) {
                HStack {
                    Text("Nothing is selected automatically. File dates show modification, not proven last use.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(scanning || isSnapshot)
                }
                .padding()
                if let message { Text(message).foregroundStyle(.orange).padding(.horizontal).textSelection(.enabled) }
                if scanning {
                    ProgressView("Inspecting Xcode storage and activity…").padding()
                }
                if !inventory.issues.isEmpty {
                    Text(inventory.issues.joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.orange).padding().textSelection(.enabled)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(XcodeCleanupCategory.allCases) { category in
                            categorySection(category)
                        }
                    }
                    .padding()
                }
                HStack {
                    Text(
                        "\(selected.count) selected · \(selectedBytes.formattedFileSize)"
                    )
                    Spacer()
                    Button("Review Selected…") { showingReview = true }
                        .disabled(selectedTargets.isEmpty || scanning || isSnapshot)
                }
                .padding()
            }
        }
        .task { if !isSnapshot { await refresh() } }
        .cleanupReview(
            isPresented: $showingReview, items: selectedTargets.map(\.preview), disposition: .mixed,
            note: reviewNote, onConfirm: removeSelected)
    }

    private var selectedTargets: [XcodeCleanupTarget] {
        inventory.targets.filter { selected.contains($0.id) && $0.canRemove }
    }

    private var selectedBytes: Int64 {
        selectedTargets.compactMap(\.bytes).reduce(0) { total, bytes in
            let (next, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? Int64.max : next
        }
    }

    private var reviewNote: String {
        selectedTargets.map { "\($0.name): \($0.mechanism.description). \($0.mechanism.cost)" }
            .joined(separator: "\n")
    }

    private func categorySection(_ category: XcodeCleanupCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(category.title).font(.headline)
            let targets = inventory.targets.filter { $0.category == category }
            if targets.isEmpty {
                Text("No targets found. Missing tools and unreadable locations are reported above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(targets) { target in
                XcodeCleanupRow(target: target, isSelected: selected.contains(target.id)) {
                    if selected.contains(target.id) { selected.remove(target.id) } else { selected.insert(target.id) }
                }
            }
        }
    }

    private func refresh() async {
        scanning = true
        selected = []
        defer { scanning = false }
        inventory = await service.scan()
    }

    private func removeSelected() async -> CleanupResult? {
        let targets = selectedTargets
        let receipt = await service.remove(targets, confirmed: true)
        message = receipt.errors.isEmpty ? nil : receipt.errors.joined(separator: "\n")
        await refresh()
        if receipt.trashedBytes > 0 {
            let detail = "\(receipt.trashedBytes.formattedFileSize) moved to Trash; empty Trash to recover that space."
            message = [message, detail].compactMap { $0 }.joined(separator: "\n")
        }
        let accounting = CleanupAccounting(
            estimatedTargetBytes: targets.compactMap(\.bytes).reduce(0, +),
            estimatedProcessedBytes: receipt.removedTargetBytes + receipt.trashedBytes,
            movedToTrashBytes: receipt.trashedBytes, permanentlyRemovedTargetBytes: 0,
            removedLocalCopyBytes: 0, toolProcessedBytes: receipt.removedTargetBytes,
            volumeObservations: receipt.observation.map { [$0] } ?? [])
        return CleanupResult(
            itemsProcessed: receipt.removedIDs.count, bytesFreed: receipt.removedTargetBytes,
            errors: receipt.errors.map { CleanupError(path: URL(fileURLWithPath: "/"), message: $0) },
            accounting: accounting)
    }
}

private struct XcodeCleanupRow: View {
    let target: XcodeCleanupTarget
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(target.name, isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden().disabled(!target.canRemove)
                .accessibilityLabel("Select \(target.name)")
            VStack(alignment: .leading, spacing: 5) {
                Text(target.name).fontWeight(.medium)
                Text(target.path.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(target.mechanism.description).font(.caption).textSelection(.enabled)
                Text(target.retentionReason ?? "Review required. \(target.mechanism.cost)")
                    .font(.caption).foregroundStyle(target.canRemove ? Color.secondary : Color.orange)
                if let date = target.lastUsed {
                    Text("\(target.category == .runtimes ? "Last used" : "Modified"): \(date.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Last use unknown").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(target.bytes?.formattedFileSize ?? "Size unavailable").font(.caption)
            Button("Reveal", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([target.path])
            }
            .labelStyle(.iconOnly).help("Reveal in Finder")
        }
        .padding().macSweepCard()
    }
}
