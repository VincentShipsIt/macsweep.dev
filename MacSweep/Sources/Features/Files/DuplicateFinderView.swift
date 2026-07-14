import SwiftUI
import AppKit
import QuickLook

/// View for finding duplicate files and removing redundant copies.
struct DuplicateFinderView: View {
    @StateObject private var model = ScanFeatureModel()
    @State private var sortOrder: CleanupSortOrder = .sizeDesc
    @State private var reviewGroups: [FileReviewGroup] = []
    @State private var keeperIDs: [FileReviewGroup.ID: CleanupItem.ID] = [:]
    @State private var previewURL: URL?

    var body: some View {
        FeaturePageShell(
            title: "Duplicate Files",
            subtitle: "Compare confirmed copies and choose exactly which one to keep.",
            trailing: model.items.isEmpty ? nil : AnyView(
                RescanButton(isScanning: model.isScanning, usesNativeToolbarStyle: true) {
                    Task { await scanDuplicates() }
                }
            ),
            hidesChrome: model.items.isEmpty,
            scrolls: model.items.isEmpty
        ) {
            if let errorMessage = model.errorMessage {
                MacSweepErrorBanner(message: errorMessage) {
                    model.errorMessage = nil
                }
            }

            if model.items.isEmpty {
                if model.hasScanned && !model.isScanning && model.errorMessage == nil {
                    EmptyResultState(
                        icon: "checkmark.circle",
                        title: "No duplicate groups remain",
                        message: "No confirmed duplicate files are waiting for review.",
                        actionTitle: "Scan Again",
                        action: { Task { await scanDuplicates() } }
                    )
                } else {
                    ScanLandingView(
                        icon: "doc.on.doc",
                        title: "Find Duplicate Files",
                        description: "Find byte-for-byte matches and compare every copy before cleanup.",
                        ctaTitle: "Scan for Duplicates",
                        benefits: [
                            ScanBenefit(
                                "doc.on.doc",
                                "Reclaims wasted space",
                                "Finds byte-for-byte identical copies scattered across your files."
                            ),
                            ScanBenefit(
                                "trash.slash",
                                "Keeps one, removes the rest",
                                "Review each group, preview its files, and choose the copy you want to keep."
                            )
                        ],
                        illustration: "doc.on.doc.fill",
                        isScanning: model.isScanning,
                        action: { Task { await scanDuplicates() } }
                    )
                }
            } else {
                ManualReviewNotice(
                    message: "Review-only results — MacSweep suggests one keeper per group and "
                        + "selects nothing until you choose."
                )
                filterBar
                Divider()
                groupsList
                footer
            }
        }
        .quickLookPreview($previewURL)
        .onDisappear { model.cancelScan() }
    }

    private var filterBar: some View {
        HStack {
            HStack {
                Text("Sort copies:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $sortOrder) {
                    ForEach(CleanupSortOrder.standardCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            Spacer()

            Text("\(visibleGroups.count) groups • \(reviewItemCount) files • \(recoverableSize) recoverable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var groupsList: some View {
        List {
            ForEach(visibleGroups) { group in
                Section {
                    ForEach(group.items.sorted(using: sortOrder)) { item in
                        DuplicateItemRow(
                            item: item,
                            isSelected: model.selectedItems.contains(item.id),
                            isKeeper: currentKeeperID(for: group) == item.id,
                            onToggle: { toggleSelection(for: item, in: group) },
                            onKeep: { chooseKeeper(item.id, in: group) },
                            onPreview: { previewURL = item.path }
                        )
                    }
                } header: {
                    FileReviewGroupHeader(
                        title: group.title,
                        itemCount: group.items.count,
                        recoverableBytes: recoverableBytes(in: group),
                        suggestionReason: group.suggestionReason
                    )
                }
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var footer: some View {
        CleanupFooter(
            selectedCount: model.selectedItems.count,
            summary: "Will recover \(selectedSize)",
            selectAllTitle: "Select Suggested Copies",
            onSelectAll: selectSuggestedCopies,
            actionTitle: "Move to Trash",
            actionDisabled: model.selectedItems.isEmpty,
            onAction: { model.showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $model.showingConfirmation,
            items: selectedDuplicates,
            disposition: .trash,
            note: "Every group retains its chosen keeper. Only the explicitly selected copies will move to Trash.",
            onConfirm: { await deleteSelected() }
        )
    }

    private func scanDuplicates() async {
        reviewGroups = []
        keeperIDs = [:]

        await model.scan(
            selectAllOnCompletion: false,
            onError: { "Couldn't scan for duplicates: \($0.localizedDescription)" },
            {
                let token = model.activeScanToken
                let groups = try await DuplicateFinderModule().scanReviewGroups()
                try Task.checkCancellation()
                await MainActor.run {
                    // A rescan started while scanning supersedes this result;
                    // defer to it instead of clobbering the newer review state.
                    guard model.isCurrent(token) else { return }
                    reviewGroups = groups
                    keeperIDs = Dictionary(
                        uniqueKeysWithValues: groups.map { ($0.id, $0.suggestedKeeperID) }
                    )
                }
                return groups.flatMap(\.items)
            }
        )
    }

    private func deleteSelected() async -> CleanupResult? {
        let result = await model.clean(selectedDuplicates) {
            "Couldn't move duplicates to Trash: \($0.localizedDescription)"
        }
        if result != nil {
            // Drop a stale Quick Look preview if its file just moved to Trash.
            if let url = previewURL, !model.items.contains(where: { $0.path == url }) {
                previewURL = nil
            }
            pruneResolvedGroups()
        }
        return result
    }

    private func toggleSelection(for item: CleanupItem, in group: FileReviewGroup) {
        guard item.id != currentKeeperID(for: group) else { return }
        if model.selectedItems.contains(item.id) {
            model.selectedItems.remove(item.id)
        } else {
            model.selectedItems.insert(item.id)
        }
    }

    private func chooseKeeper(_ itemID: CleanupItem.ID, in group: FileReviewGroup) {
        guard group.items.contains(where: { $0.id == itemID }) else { return }
        keeperIDs[group.id] = itemID
        model.selectedItems.subtract(group.items.map(\.id))
        model.selectedItems.formUnion(group.cleanupIDs(keeping: itemID))
    }

    private func selectSuggestedCopies() {
        model.selectedItems = visibleGroups.reduce(into: Set<CleanupItem.ID>()) { selection, group in
            selection.formUnion(group.cleanupIDs(keeping: currentKeeperID(for: group)))
        }
    }

    private func pruneResolvedGroups() {
        let liveIDs = Set(model.items.map(\.id))
        reviewGroups = reviewGroups.compactMap { $0.retainingItems(withIDs: liveIDs) }
        let unresolvedIDs = Set(reviewGroups.flatMap { $0.items.map(\.id) })
        model.items.removeAll { !unresolvedIDs.contains($0.id) }
        model.selectedItems.formIntersection(unresolvedIDs)
        let groupIDs = Set(reviewGroups.map(\.id))
        keeperIDs = keeperIDs.filter { groupIDs.contains($0.key) }
    }

    private func currentKeeperID(for group: FileReviewGroup) -> CleanupItem.ID {
        keeperIDs[group.id] ?? group.suggestedKeeperID
    }

    private var visibleGroups: [FileReviewGroup] {
        let liveIDs = Set(model.items.map(\.id))
        return reviewGroups.compactMap { $0.retainingItems(withIDs: liveIDs) }
    }

    private var reviewItemCount: Int {
        visibleGroups.reduce(0) { $0 + $1.items.count }
    }

    private var recoverableSize: String {
        visibleGroups.reduce(0) { $0 + recoverableBytes(in: $1) }.formattedFileSize
    }

    private func recoverableBytes(in group: FileReviewGroup) -> Int64 {
        let keeperID = currentKeeperID(for: group)
        return group.items.lazy.filter { $0.id != keeperID }.reduce(0) { $0 + $1.size }
    }

    private var selectedSize: String {
        model.items.formattedTotalSize(selected: model.selectedItems)
    }

    private var selectedDuplicates: [CleanupItem] {
        model.items.filter { model.selectedItems.contains($0.id) }
    }
}

private struct DuplicateItemRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let isKeeper: Bool
    let onToggle: () -> Void
    let onKeep: () -> Void
    let onPreview: () -> Void

    var body: some View {
        FileReviewItemRow(
            isSelected: isSelected,
            isKeeper: isKeeper,
            onToggle: onToggle
        ) {
            FileIconView(url: item.path)
                .frame(width: 36, height: 36)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)

                Text(item.path.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if isKeeper {
                    Text("Keeping this copy")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(.headline)

                if let date = item.lastModified {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !isKeeper {
                Button("Keep This One", action: onKeep)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Keep this copy and select the other files in its group")
            }

            Button(action: onPreview) {
                Image(systemName: "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quick Look")
            .accessibilityLabel("Preview \(item.displayName)")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.displayName) in Finder")
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    DuplicateFinderView()
        .frame(width: 820, height: 620)
}

#endif
