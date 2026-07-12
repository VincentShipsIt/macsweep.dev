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
    @State private var hasScanned = false
    @State private var errorMessage: String?

    var body: some View {
        FeaturePageShell(
            title: "Trash Bins",
            subtitle: "Review and empty every trash bin on your Mac.",
            trailing: AnyView(
                Button {
                    showingEmptyAllConfirmation = true
                } label: {
                    Label("Empty All Trash", systemImage: "trash.slash")
                }
                .glassButton(prominent: true)
                .tint(.red)
                .controlSize(.small)
                .disabled((trashItems.isEmpty && (trashSummary?.totalCount ?? 0) == 0) || isScanning)
                .cleanupReview(
                    isPresented: $showingEmptyAllConfirmation,
                    items: trashItems,
                    disposition: .permanent,
                    note: "This empties every scanned Trash item. It cannot be undone.",
                    onConfirm: { await emptyAllTrash() }
                )
            ),
            hidesChrome: trashItems.isEmpty && !(hasScanned && !isScanning && errorMessage == nil),
            scrolls: trashItems.isEmpty
        ) {
            VStack(spacing: 0) {
                if let errorMessage {
                    MacSweepErrorBanner(message: errorMessage) {
                        self.errorMessage = nil
                    }
                }

                if trashItems.isEmpty {
                    if hasScanned && !isScanning && errorMessage == nil {
                        emptyTrashState
                    } else {
                        ScanLandingView(
                            icon: "trash",
                            title: "Scan Trash Bins",
                            description: "Find what's sitting in your trash bins across all volumes before emptying.",
                            ctaTitle: "Scan Trash Bins",
                            benefits: [
                                ScanBenefit("externaldrive.badge.xmark", "Every bin in one place", "Gathers what's sitting in trash across all your volumes and drives so nothing is forgotten."),
                                ScanBenefit("arrow.uturn.backward", "Reclaim before you delete", "Review each item and put anything back to its original spot until you confirm it's gone for good."),
                            ],
                            illustration: "trash",
                            isScanning: isScanning,
                            scanningMessage: "Scanning trash bins",
                            action: { Task { await scanTrash() } }
                        )
                    }
                } else {
                    trashList
                    Divider()
                    footer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await loadTrashSummary()
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
        .macSweepListSurface()
    }

    // MARK: - Footer

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedItems.count,
            summary: "Will permanently delete \(selectedSize)",
            onSelectAll: { selectedItems = Set(trashItems.map(\.id)) },
            actionTitle: "Delete Selected",
            actionDisabled: selectedItems.isEmpty,
            onAction: { showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $showingConfirmation,
            items: selectedTrashItems,
            disposition: .permanent,
            onConfirm: { await deleteSelected() }
        )
    }

    private var emptyTrashState: some View {
        EmptyResultState(
            icon: "checkmark.circle",
            title: "Trash bins are empty",
            message: "No cleanable items were found in your Trash bins.",
            actionTitle: "Scan Again",
            action: { Task { await scanTrash() } }
        )
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
        guard !isScanning else { return }

        isScanning = true
        trashItems = []
        selectedItems = []
        errorMessage = nil

        defer {
            isScanning = false
            hasScanned = true
        }

        let module = TrashBinsModule()
        do {
            trashItems = try await module.scan()
            trashSummary = await TrashSummary.current()
        } catch {
            trashSummary = await TrashSummary.current()
            errorMessage = "Couldn't scan Trash bins: \(error.localizedDescription)"
        }
    }

    private func deleteSelected() async -> CleanupResult? {
        let itemsToDelete = selectedTrashItems
        var deletionError: String?
        var cleanupResult: CleanupResult?

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        let engine = ScanEngine()
        do {
            let result = try await engine.clean(items: itemsToDelete, dryRun: false, confirmedLargeDeletion: true)
            cleanupResult = result
            if !result.errors.isEmpty {
                let count = result.errors.count
                deletionError = "\(count) item\(count == 1 ? "" : "s") couldn't be deleted and were kept."
            }
        } catch {
            deletionError = "Couldn't delete selected Trash items: \(error.localizedDescription)"
        }

        // Refresh
        await scanTrash()
        if let deletionError {
            errorMessage = deletionError
        }
        return cleanupResult
    }

    private func emptyAllTrash() async -> CleanupResult? {
        guard !isScanning else { return nil }

        isScanning = true
        errorMessage = nil

        defer {
            isScanning = false
            hasScanned = true
        }

        let engine = ScanEngine()
        do {
            let result = try await engine.clean(items: trashItems, dryRun: false, confirmedLargeDeletion: true)
            trashItems = try await TrashBinsModule().scan()
            trashSummary = await TrashSummary.current()
            return result
        } catch {
            trashSummary = await TrashSummary.current()
            errorMessage = "Couldn't empty Trash: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Helpers

    private var selectedSize: String {
        trashItems.formattedTotalSize(selected: selectedItems)
    }

    private var selectedTrashItems: [CleanupItem] {
        trashItems.filter { selectedItems.contains($0.id) }
    }

    private func formattedSize(for items: [CleanupItem]) -> String {
        items.formattedTotalSize()
    }
}

// MARK: - Trash Item Row

struct TrashItemRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            // File icon
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path.path))
                .resizable()
                .frame(width: 32, height: 32)
        } content: {
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
        } trailing: {
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
    }

    private func putBack(_ item: CleanupItem) {
        // Escape the path for an AppleScript string literal: backslash first, then
        // double-quote. Without this, a trashed file whose name contains a `"`
        // would break out of the string and inject arbitrary AppleScript.
        let escapedPath = item.path.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Use Finder to put back
        let script = """
        tell application "Finder"
            set theItem to POSIX file "\(escapedPath)" as alias
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
