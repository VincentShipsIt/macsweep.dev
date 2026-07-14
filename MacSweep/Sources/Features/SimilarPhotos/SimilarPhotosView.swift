import SwiftUI
import AppKit
import QuickLook

/// View for finding visually similar photos.
struct SimilarPhotosView: View {
    @StateObject private var model = ScanFeatureModel()
    @State private var sortOrder: CleanupSortOrder = .sizeDesc
    @State private var reviewGroups: [FileReviewGroup] = []
    @State private var keeperIDs: [FileReviewGroup.ID: CleanupItem.ID] = [:]
    @State private var previewURL: URL?

    var body: some View {
        FeaturePageShell(
            title: "Similar Photos",
            subtitle: "Inspect look-alike clusters and choose the best shot to keep.",
            trailing: model.items.isEmpty ? nil : AnyView(
                RescanButton(isScanning: model.isScanning, usesNativeToolbarStyle: true) {
                    Task { await scanPhotos() }
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
                        title: "No similar-photo clusters remain",
                        message: "No look-alike photos are waiting for review.",
                        actionTitle: "Scan Again",
                        action: { Task { await scanPhotos() } }
                    )
                } else {
                    ScanLandingView(
                        icon: "photo.stack",
                        title: "Find Similar Photos",
                        description: "Compare photo fingerprints to detect look-alike shots and inspect each cluster.",
                        ctaTitle: "Scan Photos",
                        benefits: [
                            ScanBenefit(
                                "rectangle.on.rectangle",
                                "Clears out near-duplicates",
                                "Groups burst shots and look-alike photos so you can compare them together."
                            ),
                            ScanBenefit(
                                "star",
                                "Keeps your best shot",
                                "Preview each image and choose the keeper before any extras move to Trash."
                            )
                        ],
                        illustration: "photo.on.rectangle.angled",
                        isScanning: model.isScanning,
                        action: { Task { await scanPhotos() } }
                    )
                }
            } else {
                ManualReviewNotice(
                    message: "Review-only results — preview each cluster and confirm its keeper "
                        + "before selecting photos to remove."
                )
                filterBar
                Divider()
                groupsList
                Divider()
                footer
            }
        }
        .quickLookPreview($previewURL)
        .onDisappear { model.cancelScan() }
    }

    private var filterBar: some View {
        HStack {
            HStack {
                Text("Sort photos:")
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

            Text("\(visibleGroups.count) clusters • \(reviewItemCount) photos • \(recoverableSize) recoverable")
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
                        SimilarPhotoRow(
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
            selectAllTitle: "Select Suggested Photos",
            onSelectAll: selectSuggestedPhotos,
            actionTitle: "Move to Trash",
            actionDisabled: model.selectedItems.isEmpty,
            onAction: { model.showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $model.showingConfirmation,
            items: selectedPhotos,
            disposition: .trash,
            note: "Every cluster retains its chosen keeper. Only the explicitly selected photos will move to Trash.",
            onConfirm: { await cleanSelected() }
        )
    }

    private func scanPhotos() async {
        reviewGroups = []
        keeperIDs = [:]

        await model.scan(
            selectAllOnCompletion: false,
            onError: { "Couldn't scan for similar photos: \($0.localizedDescription)" },
            {
                let groups = try await SimilarPhotosModule().scanReviewGroups()
                await MainActor.run {
                    reviewGroups = groups
                    keeperIDs = Dictionary(
                        uniqueKeysWithValues: groups.map { ($0.id, $0.suggestedKeeperID) }
                    )
                }
                return groups.flatMap(\.items)
            }
        )
    }

    private func cleanSelected() async -> CleanupResult? {
        let result = await model.clean(selectedPhotos) {
            "Couldn't move photos to Trash: \($0.localizedDescription)"
        }
        if result != nil {
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

    private func selectSuggestedPhotos() {
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

    private var selectedPhotos: [CleanupItem] {
        model.items.filter { model.selectedItems.contains($0.id) }
    }
}

private struct SimilarPhotoRow: View {
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
            SimilarPhotoThumbnail(url: item.path)
                .frame(width: 52, height: 52)
                .compositingGroup()
                .clipShape(.rect(cornerRadius: 8))
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)

                Text(item.path.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if isKeeper {
                    Text("Keeping this photo")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 3) {
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
                    .help("Keep this photo and select the other photos in its cluster")
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

private struct SimilarPhotoThumbnail: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            FileIconView(url: url)
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    SimilarPhotosView()
        .frame(width: 860, height: 640)
}

#endif
