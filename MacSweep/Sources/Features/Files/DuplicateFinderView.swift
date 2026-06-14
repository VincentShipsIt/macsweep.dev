import SwiftUI
import AppKit

/// View for finding duplicate files and removing redundant copies
struct DuplicateFinderView: View {
    @State private var isScanning = false
    @State private var duplicateItems: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var sortOrder: SortOrder = .sizeDesc

    enum SortOrder: String, CaseIterable {
        case sizeDesc = "Largest First"
        case dateAsc = "Oldest First"
        case dateDesc = "Newest First"
        case nameAsc = "Name A-Z"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()

            if isScanning {
                scanningView
            } else if duplicateItems.isEmpty {
                emptyState
            } else {
                duplicatesList
            }

            if !sortedItems.isEmpty && !isScanning {
                Divider()
                footer
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Duplicate Files")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Find redundant copies and keep only the best version")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await scanDuplicates()
                }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .glassButton(prominent: true)
            .disabled(isScanning)
        }
        .padding()
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

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning for duplicates...")
                .font(.headline)

            Text("Hashing files to identify real duplicates")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No duplicates found")
                .font(.headline)

            Text("Run a scan to find redundant file copies")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Start Scan") {
                Task {
                    await scanDuplicates()
                }
            }
            .glassButton(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            "Move \(selectedItems.count) duplicates to Trash?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await deleteSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move \(selectedSize) of duplicate files to Trash.")
        }
    }

    private func scanDuplicates() async {
        isScanning = true
        duplicateItems = []
        selectedItems = []

        defer { isScanning = false }

        let module = DuplicateFinderModule()

        do {
            duplicateItems = try await module.scan()
            selectedItems = Set(duplicateItems.map(\.id))
        } catch {
            print("Duplicate scan error: \(error)")
        }
    }

    private func deleteSelected() async {
        let itemsToDelete = sortedItems.filter { selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        let engine = ScanEngine()
        do {
            _ = try await engine.clean(items: itemsToDelete, dryRun: false)
        } catch {
            print("Duplicate cleanup error: \(error)")
        }

        duplicateItems.removeAll { selectedItems.contains($0.id) }
        selectedItems.removeAll()
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
        let total = sortedItems.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var selectedSize: String {
        let total = sortedItems
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

struct DuplicateItemRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            FileIconView(url: item.path)
                .frame(width: 36, height: 36)

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

            Spacer()

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
        .padding(.vertical, 4)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    DuplicateFinderView()
        .frame(width: 720, height: 520)
}

#endif
