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
                Button { Task { await scanPhotos() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .glassButton().controlSize(.small).disabled(model.isScanning)
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectedItems.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Will recover \(selectedSize)")
                    .font(.headline)
            }

            Spacer()

            Button("Select All") {
                model.selectAll(sortedItems)
            }
            .glassButton()

            Button("Move to Trash") {
                model.showingConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(model.selectedItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Move \(model.selectedItems.count) similar photos to Trash?",
            isPresented: $model.showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await cleanSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected similar photos will be moved to Trash so you can restore them if needed.")
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
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            SimilarPhotoThumbnail(url: item.path)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 8))

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

            Spacer()

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
        .padding(.vertical, 4)
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
