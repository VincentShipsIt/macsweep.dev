import SwiftUI
import AppKit

/// View for finding duplicate files and removing redundant copies
struct DuplicateFinderView: View {
    @State private var isScanning = false
    @State private var duplicateItems: [CleanupItem] = []
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
            title: "Duplicate Files",
            subtitle: "Find redundant copies and keep the best version.",
            trailing: duplicateItems.isEmpty ? nil : AnyView(
                RescanButton(isScanning: isScanning) { Task { await scanDuplicates() } }
            ),
            hidesChrome: duplicateItems.isEmpty,
            scrolls: duplicateItems.isEmpty
        ) {
            if let errorMessage {
                MacSweepErrorBanner(message: errorMessage) {
                    self.errorMessage = nil
                }
            }

            if duplicateItems.isEmpty {
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
                    isScanning: isScanning,
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

            Text("\(sortedItems.count) duplicates • \(totalSize) recoverable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var duplicatesList: some View {
        List(selection: $selectedItems) {
            ForEach(sortedItems) { item in
                DuplicateItemRow(
                    item: item,
                    isSelected: selectedItems.contains(item.id)
                )
                .tag(item.id)
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedItems.count,
            summary: "Will recover \(selectedSize)",
            onSelectAll: { selectedItems = Set(sortedItems.map(\.id)) },
            actionTitle: "Move to Trash",
            actionDisabled: selectedItems.isEmpty,
            onAction: { showingConfirmation = true }
        )
        .deleteConfirmation(
            "Move \(selectedItems.count) duplicates to Trash?",
            isPresented: $showingConfirmation,
            confirmTitle: "Move to Trash",
            message: "This will move \(selectedSize) of duplicate files to Trash."
        ) {
            Task { await deleteSelected() }
        }
    }

    private func scanDuplicates() async {
        isScanning = true
        duplicateItems = []
        selectedItems = []
        errorMessage = nil

        defer { isScanning = false }

        let module = DuplicateFinderModule()

        do {
            duplicateItems = try await module.scan()
            selectedItems = Set(duplicateItems.map(\.id))
        } catch {
            errorMessage = "Couldn't scan for duplicates: \(error.localizedDescription)"
        }
    }

    private func deleteSelected() async {
        let itemsToDelete = sortedItems.filter { selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        let engine = ScanEngine()
        let result: CleanupResult
        do {
            result = try await engine.clean(items: itemsToDelete, dryRun: false, confirmedLargeDeletion: true)
        } catch {
            errorMessage = "Couldn't move duplicates to Trash: \(error.localizedDescription)"
            return
        }

        // Per-item failures are returned in result.errors (not thrown), so only
        // drop the items that actually left disk — keep failed ones visible and
        // tell the user, rather than silently removing them from the list.
        let failedPaths = Set(result.errors.map(\.path))
        duplicateItems.removeAll { selectedItems.contains($0.id) && !failedPaths.contains($0.path) }
        selectedItems = selectedItems.filter { id in duplicateItems.contains(where: { $0.id == id }) }
        errorMessage = result.failureSummaryMessage
    }

    private var sortedItems: [CleanupItem] {
        var items = duplicateItems

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
        sortedItems.formattedTotalSize()
    }

    private var selectedSize: String {
        sortedItems.formattedTotalSize(selected: selectedItems)
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
