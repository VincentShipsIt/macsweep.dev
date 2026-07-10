import SwiftUI
import AppKit

/// View for finding visually similar photos.
struct SimilarPhotosView: View {
    @StateObject private var model = ScanFeatureModel()
    @State private var sortOrder: CleanupSortOrder = .sizeDesc

    var body: some View {
        FeaturePageShell(
            title: "Similar Photos",
            subtitle: "Detect look-alike images and keep the best shot.",
            trailing: model.items.isEmpty ? nil : AnyView(
                RescanButton(isScanning: model.isScanning) { Task { await scanPhotos() } }
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
                ScanLandingView(
                    icon: "photo.stack",
                    title: "Find Similar Photos",
                    description: "Compare photo fingerprints to detect visually similar shots and keep the strongest one.",
                    ctaTitle: "Scan Photos",
                    benefits: [
                        ScanBenefit("rectangle.on.rectangle", "Clears out near-duplicates", "Groups burst shots and look-alike photos so you can delete the extras and reclaim storage."),
                        ScanBenefit("star", "Keeps your best shot", "Compares each photo so you always choose the sharpest, best-framed version before anything is removed."),
                    ],
                    illustration: "photo.on.rectangle.angled",
                    isScanning: model.isScanning,
                    action: { Task { await scanPhotos() } }
                )
            } else {
                filterBar
                Divider()
                itemsList
                Divider()
                footer
            }
        }
        .onDisappear { model.cancelScan() }
    }

    private var filterBar: some View {
        HStack {
            HStack {
                Text("Sort:")
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

            Text("\(sortedItems.count) photos • \(totalSize) recoverable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var itemsList: some View {
        List(selection: $model.selectedItems) {
            ForEach(sortedItems) { item in
                SimilarPhotoRow(item: item, isSelected: model.selectedItems.contains(item.id))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var footer: some View {
        CleanupFooter(
            selectedCount: model.selectedItems.count,
            summary: "Will recover \(selectedSize)",
            onSelectAll: { model.selectAll(sortedItems) },
            actionTitle: "Move to Trash",
            actionDisabled: model.selectedItems.isEmpty,
            onAction: { model.showingConfirmation = true }
        )
        .deleteConfirmation(
            "Move \(model.selectedItems.count) similar photos to Trash?",
            isPresented: $model.showingConfirmation,
            confirmTitle: "Move to Trash",
            message: "The selected similar photos will be moved to Trash so you can restore them if needed."
        ) {
            Task { await cleanSelected() }
        }
    }

    private func scanPhotos() async {
        await model.scan(onError: { "Couldn't scan for similar photos: \($0.localizedDescription)" }) {
            try await SimilarPhotosModule().scan()
        }
    }

    private func cleanSelected() async {
        // The shared model routes through ScanEngine (per-item SafetyChecker +
        // aggregate DeletionGuard cap), then prunes only the photos that left disk.
        let itemsToClean = sortedItems.filter { model.selectedItems.contains($0.id) }
        await model.clean(itemsToClean) { "Couldn't move photos to Trash: \($0.localizedDescription)" }
    }

    private var sortedItems: [CleanupItem] {
        model.items.sorted(using: sortOrder)
    }

    private var totalSize: String {
        sortedItems.formattedTotalSize()
    }

    private var selectedSize: String {
        sortedItems.formattedTotalSize(selected: model.selectedItems)
    }
}

private struct SimilarPhotoRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            SimilarPhotoThumbnail(url: item.path)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 8))
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)

                Text(item.moduleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(item.path.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
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

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
        .frame(width: 760, height: 540)
}

#endif
