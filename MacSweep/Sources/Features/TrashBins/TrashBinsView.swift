import SwiftUI

/// View for managing and emptying trash bins
struct TrashBinsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var trashItems: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var showingEmptyAllConfirmation = false
    @State private var trashSummary: TrashSummary?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isScanning {
                scanningView
            } else if trashItems.isEmpty {
                emptyState
            } else {
                trashList
            }

            if !trashItems.isEmpty && !isScanning {
                Divider()
                footer
            }
        }
        .task {
            await loadTrashSummary()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trash Bins")
                    .font(.title)
                    .fontWeight(.bold)

                if let summary = trashSummary {
                    Text("\(summary.totalCount) items • \(summary.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Quick empty button
            Button {
                showingEmptyAllConfirmation = true
            } label: {
                Label("Empty All Trash", systemImage: "trash.slash")
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(trashItems.isEmpty && trashSummary?.totalCount == 0)

            Button {
                Task {
                    await scanTrash()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isScanning)
        }
        .padding()
        .confirmationDialog(
            "Empty All Trash?",
            isPresented: $showingEmptyAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                Task {
                    await emptyAllTrash()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let summary = trashSummary {
                Text("This will permanently delete \(summary.totalCount) items (\(summary.formattedSize)). This cannot be undone.")
            } else {
                Text("This will permanently delete all items in Trash. This cannot be undone.")
            }
        }
    }

    // MARK: - Trash List

    private var trashList: some View {
        List(selection: $selectedItems) {
            // Group by trash bin
            let groupedItems = Dictionary(grouping: trashItems, by: { $0.moduleName })

            ForEach(Array(groupedItems.keys.sorted()), id: \.self) { binName in
                Section {
                    ForEach(groupedItems[binName] ?? []) { item in
                        TrashItemRow(item: item, isSelected: selectedItems.contains(item.id))
                            .tag(item.id)
                    }
                } header: {
                    HStack {
                        Image(systemName: "trash")
                        Text(binName)
                        Spacer()
                        Text(formattedSize(for: groupedItems[binName] ?? []))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "trash.slash")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("Trash is Empty")
                .font(.headline)

            Text("No items in any trash bins")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning trash bins...")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedItems.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Will permanently delete \(selectedSize)")
                    .font(.headline)
            }

            Spacer()

            Button("Select All") {
                selectedItems = Set(trashItems.map(\.id))
            }
            .glassButton()

            Button("Delete Selected") {
                showingConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(selectedItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Permanently Delete \(selectedItems.count) Items?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                Task {
                    await deleteSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete \(selectedSize) of files. This cannot be undone.")
        }
    }

    // MARK: - Actions

    private func loadTrashSummary() async {
        trashSummary = await TrashSummary.current()

        // Auto-scan if there are items
        if trashSummary?.totalCount ?? 0 > 0 {
            await scanTrash()
        }
    }

    private func scanTrash() async {
        isScanning = true
        trashItems = []
        selectedItems = []

        defer { isScanning = false }

        let module = TrashBinsModule()
        trashItems = (try? await module.scan()) ?? []
        trashSummary = await TrashSummary.current()
    }

    private func deleteSelected() async {
        let itemsToDelete = trashItems.filter { selectedItems.contains($0.id) }
        let module = TrashBinsModule()

        _ = try? await module.clean(items: itemsToDelete, dryRun: false)

        // Refresh
        await scanTrash()
    }

    private func emptyAllTrash() async {
        let module = TrashBinsModule()
        try? await module.emptyAllTrash()

        // Refresh
        await scanTrash()
    }

    // MARK: - Helpers

    private var selectedSize: String {
        let total = trashItems
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func formattedSize(for items: [CleanupItem]) -> String {
        let total = items.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Trash Item Row

struct TrashItemRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            // File icon
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path.path))
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let date = item.lastModified {
                        Text("Deleted \(date, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(item.path.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Text(item.formattedSize)
                .font(.headline)

            // Put back option
            Button {
                putBack(item)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Put Back")
        }
        .padding(.vertical, 4)
    }

    private func putBack(_ item: CleanupItem) {
        // Use Finder to put back
        let script = """
        tell application "Finder"
            set theItem to POSIX file "\(item.path.path)" as alias
            move theItem to original location
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    TrashBinsView()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}

#endif
