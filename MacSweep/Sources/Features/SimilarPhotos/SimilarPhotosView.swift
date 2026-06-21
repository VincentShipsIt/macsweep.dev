import SwiftUI
import AppKit

/// View for finding visually similar photos.
struct SimilarPhotosView: View {
    @State private var isScanning = false
    @State private var photoItems: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var sortOrder: SortOrder = .sizeDesc
    @State private var errorMessage: String?

    enum SortOrder: String, CaseIterable {
        case sizeDesc = "Largest First"
        case dateAsc = "Oldest First"
        case dateDesc = "Newest First"
        case nameAsc = "Name A-Z"
    }

    var body: some View {
        FeaturePageShell(
            title: "Similar Photos",
            subtitle: "Detect look-alike images and keep the best shot.",
            trailing: photoItems.isEmpty ? nil : AnyView(
                Button { Task { await scanPhotos() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .glassButton().controlSize(.small).disabled(isScanning)
            )
        ) {
            if let errorMessage {
                errorBanner(errorMessage)
            }

            if photoItems.isEmpty {
                ScanLandingView(
                    icon: "photo.stack",
                    title: "Find Similar Photos",
                    description: "Compare photo fingerprints to detect visually similar shots and keep the strongest one.",
                    ctaTitle: "Scan Photos",
                    isScanning: isScanning,
                    action: { Task { await scanPhotos() } }
                )
            } else {
                filterBar
                Divider().overlay(MacSweepTheme.divider)
                itemsList
                Divider().overlay(MacSweepTheme.divider)
                footer
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.caption)
            Spacer()
            Button { errorMessage = nil } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }

    private var filterBar: some View {
        HStack {
            HStack {
                Text("Sort:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
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
        List(selection: $selectedItems) {
            ForEach(sortedItems) { item in
                SimilarPhotoRow(item: item, isSelected: selectedItems.contains(item.id))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedItems.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Will recover \(selectedSize)")
                    .font(.headline)
            }

            Spacer()

            Button("Select All") {
                selectedItems = Set(sortedItems.map(\.id))
            }
            .glassButton()

            Button("Move to Trash") {
                showingConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(selectedItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Move \(selectedItems.count) similar photos to Trash?",
            isPresented: $showingConfirmation,
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
        isScanning = true
        photoItems = []
        selectedItems = []
        errorMessage = nil
        defer { isScanning = false }

        do {
            let module = SimilarPhotosModule()
            photoItems = try await module.scan()
            selectedItems = Set(photoItems.map(\.id))
        } catch {
            errorMessage = "Couldn't scan for similar photos: \(error.localizedDescription)"
        }
    }

    private func cleanSelected() async {
        let itemsToClean = sortedItems.filter { selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        let engine = ScanEngine()
        do {
            _ = try await engine.clean(items: itemsToClean, dryRun: false)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't move photos to Trash: \(error.localizedDescription)"
            return
        }
        photoItems.removeAll { selectedItems.contains($0.id) }
        selectedItems.removeAll()
    }

    private var sortedItems: [CleanupItem] {
        var items = photoItems

        switch sortOrder {
        case .sizeDesc:
            items.sort { $0.size > $1.size }
        case .dateAsc:
            items.sort { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        case .dateDesc:
            items.sort { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .nameAsc:
            items.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        }

        return items
    }

    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: sortedItems.reduce(0) { $0 + $1.size }, countStyle: .file)
    }

    private var selectedSize: String {
        ByteCountFormatter.string(
            fromByteCount: sortedItems.filter { selectedItems.contains($0.id) }.reduce(0) { $0 + $1.size },
            countStyle: .file
        )
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
