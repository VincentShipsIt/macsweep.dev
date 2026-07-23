import SwiftUI

/// View for managing and emptying trash bins
struct TrashBinsView: View {
    @EnvironmentObject var appState: AppState

    /// Shared scan/selection/cleanup state machine — replaces the hand-rolled
    /// `isScanning`/`trashItems`/`selectedItems`/`showingConfirmation`/`hasScanned`/
    /// `errorMessage` cluster this view used to declare inline.
    @StateObject private var model: ScanFeatureModel

    /// Trash-specific state that isn't part of the shared scan machine: the
    /// live bin summary (refreshed alongside every scan) and the "empty all"
    /// confirmation, distinct from the shared `model.showingConfirmation` that
    /// gates the selected-item deletion.
    @State private var showingEmptyAllConfirmation = false
    @State private var trashSummary: TrashSummary?

    /// When true, the auto-scan `.task` is skipped so injected snapshot data isn't
    /// immediately overwritten by a real Trash scan. Always false in production.
    private let disableAutoLoad: Bool

    /// Default production initializer — auto-scans on appear when Trash isn't empty.
    init() {
        _model = StateObject(wrappedValue: FeatureScanSessions.shared.trashBins)
        disableAutoLoad = false
    }

    /// Seeds the shared model directly (and suppresses the auto-scan) so the
    /// headless snapshot harness (and Xcode previews) can render the populated and
    /// error layouts without touching the real filesystem. Not used by the app's
    /// normal navigation, which constructs the view with the no-arg initializer.
    init(
        snapshotItems: [CleanupItem],
        snapshotSelection: Set<UUID> = [],
        snapshotIsScanning: Bool = false,
        snapshotHasScanned: Bool = false,
        snapshotError: String? = nil
    ) {
        _model = StateObject(wrappedValue: ScanFeatureModel(
            items: snapshotItems,
            selectedItems: snapshotSelection,
            isScanning: snapshotIsScanning,
            hasScanned: snapshotHasScanned,
            errorMessage: snapshotError
        ))
        disableAutoLoad = true
    }

    var body: some View {
        FeaturePageShell(
            title: "Trash Bins",
            subtitle: "Review and empty every trash bin on your Mac.",
            trailing: AnyView(
                Button(role: .destructive) {
                    showingEmptyAllConfirmation = true
                } label: {
                    Label("Empty All Trash", systemImage: "trash.slash")
                }
                .disabled(model.items.isEmpty || model.isScanning)
                .cleanupReview(
                    isPresented: $showingEmptyAllConfirmation,
                    items: model.items,
                    disposition: .permanent,
                    note: "The scanned items are a preview. Finder empties all Trash bins, "
                        + "including items added after this scan. It cannot be undone.",
                    onConfirm: { await emptyAllTrash() }
                )
            ),
            hidesChrome: model.items.isEmpty && !(model.hasScanned && !model.isScanning && model.errorMessage == nil),
            scrolls: model.items.isEmpty
        ) {
            VStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    MacSweepErrorBanner(message: errorMessage) {
                        model.errorMessage = nil
                    }
                }

                if model.items.isEmpty {
                    if model.hasScanned && !model.isScanning && model.errorMessage == nil {
                        emptyTrashState
                            .transition(.scanCrossfade)
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
                            isScanning: model.isScanning,
                            scanningMessage: "Scanning trash bins",
                            action: { Task { await scanTrash() } }
                        )
                        .transition(.scanCrossfade)
                    }
                } else {
                    Group {
                    trashList
                    footer
                    }
                    .transition(.scanCrossfade)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Crossfade every scan-stage swap (landing ⇄ empty ⇄ results);
            // no-ops under Reduce Motion.
            .animated(.scanCrossfade, value: model.scanPhase)
        }
        .task {
            if !disableAutoLoad { await loadTrashSummary() }
        }
    }

    // MARK: - Trash List

    private var trashList: some View {
        List(selection: $model.selectedItems) {
            // Group by trash bin
            let groupedItems = Dictionary(grouping: model.items, by: { $0.moduleName })

            ForEach(Array(groupedItems.keys.sorted()), id: \.self) { binName in
                Section {
                    ForEach(groupedItems[binName] ?? []) { item in
                        TrashItemRow(item: item, isSelected: model.selectedItems.contains(item.id))
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
            selectedCount: model.selectedItems.count,
            summary: "Will permanently delete \(selectedSize)",
            onSelectAll: { model.selectAll(model.items) },
            actionTitle: "Delete Selected",
            actionDisabled: model.selectedItems.isEmpty,
            onAction: { model.showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $model.showingConfirmation,
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
        guard !model.isScanning else { return }

        // Trash starts with nothing selected — the user opts into what to delete —
        // so suppress the shared model's default select-all-on-completion. Scan
        // failures surface in the banner via `onError`.
        await model.scan(
            selectAllOnCompletion: false,
            onError: { "Couldn't scan Trash bins: \($0.localizedDescription)" }
        ) {
            try await TrashBinsModule().scan()
        }

        // Refresh the live bin summary after every scan, success or failure —
        // mirroring the original which recomputed it in both branches.
        trashSummary = await TrashSummary.current()
    }

    private func deleteSelected() async -> CleanupResult? {
        let itemsToDelete = selectedTrashItems
        var deletionError: String?
        var cleanupResult: CleanupResult?

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        //
        // Deliberately NOT `model.clean(_:)`: Trash re-scans after deletion to
        // reflect Finder-side changes and put-backs and to refresh `trashSummary`,
        // where the shared `clean(_:)` epilogue prunes the list in place instead.
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

        // Refresh (also clears the banner via the shared scan, so re-apply any
        // deletion error afterwards).
        await scanTrash()
        if let deletionError {
            model.errorMessage = deletionError
        }
        return cleanupResult
    }

    private func emptyAllTrash() async -> CleanupResult? {
        guard !model.isScanning else { return nil }

        // Finder-driven bulk empty, not a scan: drive the shared flags directly.
        // Safe because this is guarded against a concurrent scan and starts no
        // scan task of its own, so it never races the generation machinery.
        model.isScanning = true
        model.errorMessage = nil

        defer {
            model.isScanning = false
            model.hasScanned = true
        }

        let previewItems = model.items
        let module = TrashBinsModule()
        do {
            try await module.emptyAllTrash()
            model.items = try await module.scan()
            trashSummary = await TrashSummary.current()
            let result = TrashBinsModule.verifiedEmptyAllResult(
                previewItems: previewItems,
                remainingItems: model.items
            )
            for item in previewItems where result.historyActions[item.id] != nil {
                Log.deletion(path: item.path, module: item.module, disposition: .delete)
            }
            return result
        } catch {
            Log.scanError("Empty Trash failed: \(error.localizedDescription)")
            model.items = (try? await module.scan()) ?? model.items
            trashSummary = await TrashSummary.current()
            model.errorMessage = "Couldn't empty Trash: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Helpers

    private var selectedSize: String {
        model.items.formattedTotalSize(selected: model.selectedItems)
    }

    private var selectedTrashItems: [CleanupItem] {
        model.items.filter { model.selectedItems.contains($0.id) }
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
