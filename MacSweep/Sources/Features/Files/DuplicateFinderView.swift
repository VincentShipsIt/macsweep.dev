import SwiftUI
import AppKit

/// View for finding duplicate files and removing redundant copies
struct DuplicateFinderView: View {
    @StateObject private var model = ScanFeatureModel()
    @State private var sortOrder: CleanupSortOrder = .sizeDesc

    var body: some View {
        FeaturePageShell(
            title: "Duplicate Files",
            subtitle: "Find redundant copies and keep the best version.",
            trailing: model.items.isEmpty ? nil : AnyView(
                RescanButton(isScanning: model.isScanning, usesNativeToolbarStyle: true) { Task { await scanDuplicates() } }
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
                    icon: "doc.on.doc",
                    title: "Find Duplicate Files",
                    description: "Scan your files to find redundant copies so you can keep only the best version.",
                    ctaTitle: "Scan for Duplicates",
                    benefits: [
                        ScanBenefit("doc.on.doc", "Reclaims wasted space", "Finds byte-for-byte identical copies scattered across your files so you can recover the space they take up."),
                        ScanBenefit("trash.slash", "Keeps one, removes the rest", "Duplicates only move to Trash after you review them, so the version you want to keep always stays put."),
                    ],
                    illustration: "doc.on.doc.fill",
                    isScanning: model.isScanning,
                    action: { Task { await scanDuplicates() } }
                )
            } else {
                filterBar
                Divider()
                duplicatesList
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

            Text("\(sortedItems.count) duplicates • \(totalSize) recoverable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var duplicatesList: some View {
        List(selection: $model.selectedItems) {
            ForEach(sortedItems) { item in
                DuplicateItemRow(
                    item: item,
                    isSelected: model.selectedItems.contains(item.id)
                )
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
        .cleanupReview(
            isPresented: $model.showingConfirmation,
            items: selectedDuplicates,
            disposition: .trash,
            note: "Duplicate groups are review-only; only the files selected here will move.",
            onConfirm: { await deleteSelected() }
        )
    }

    private func scanDuplicates() async {
        await model.scan(onError: { "Couldn't scan for duplicates: \($0.localizedDescription)" }) {
            try await DuplicateFinderModule().scan()
        }
    }

    private func deleteSelected() async -> CleanupResult? {
        // The shared model routes through ScanEngine (per-item SafetyChecker +
        // aggregate DeletionGuard cap), then prunes only the items that left disk;
        // engine-blocked items stay in the list and a failure summary is surfaced.
        await model.clean(selectedDuplicates) { "Couldn't move duplicates to Trash: \($0.localizedDescription)" }
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

    private var selectedDuplicates: [CleanupItem] {
        sortedItems.filter { model.selectedItems.contains($0.id) }
    }
}

struct DuplicateItemRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            FileIconView(url: item.path)
                .frame(width: 36, height: 36)
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)

                Text(item.moduleName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.path.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
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

#if !SWIFT_PACKAGE
#Preview {
    DuplicateFinderView()
        .frame(width: 720, height: 520)
}

#endif
