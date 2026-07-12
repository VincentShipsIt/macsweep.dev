import SwiftUI
import AppKit

/// View for finding and managing large files
struct LargeFilesView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model = ScanFeatureModel()

    // Filters
    @State private var sizeThreshold: Double = 100  // MB
    @State private var scanKind: LargeFilesModule.ScanKind = .both
    @State private var selectedCategory: String? = nil
    @State private var sortOrder: CleanupSortOrder = .sizeDesc

    private let categories = ["All", "Folder", "Video", "Image", "Audio", "Archive", "Disk Image", "Document", "Code", "Application", "Other"]

    /// Default production initializer — empty on launch until the user scans.
    init() {}

    /// Seeds the shared model directly so the headless snapshot harness (and Xcode
    /// previews) can render the populated and error layouts, which otherwise only
    /// appear after a live scan. Not used by the app's normal navigation, which
    /// constructs the view with the no-arg initializer above.
    init(
        snapshotItems: [CleanupItem],
        snapshotSelection: Set<UUID> = [],
        snapshotError: String? = nil
    ) {
        _model = StateObject(wrappedValue: ScanFeatureModel(
            items: snapshotItems,
            selectedItems: snapshotSelection,
            errorMessage: snapshotError
        ))
    }

    var body: some View {
        FeaturePageShell(
            title: "Large & Old Files",
            subtitle: "Find large files and folders by size and age.",
            trailing: model.items.isEmpty ? nil : AnyView(
                RescanButton(isScanning: model.isScanning, usesNativeToolbarStyle: true) { Task { await scanLargeFiles() } }
            ),
            hidesChrome: model.items.isEmpty,
            scrolls: model.items.isEmpty
        ) {
            VStack(spacing: 0) {
                if let errorMessage = model.errorMessage {
                    MacSweepErrorBanner(message: errorMessage) {
                        model.errorMessage = nil
                    }
                }

                if model.items.isEmpty {
                    ScanLandingView(
                        icon: "doc.badge.clock",
                        title: "Find Large & Old Files",
                        description: "Scan to surface large files and folders ranked by size and recent activity.",
                        ctaTitle: "Scan for Large Files",
                        benefits: [
                            ScanBenefit("arrow.up.arrow.down.circle", "Reclaim the most space fast", "Ranks files and folders by size so the biggest space hogs surface first, instead of hunting through Finder."),
                            ScanBenefit("clock.badge.questionmark", "Surfaces forgotten files", "Flags large items you haven't touched in ages, like old videos, disk images, and archives you can safely let go."),
                        ],
                        illustration: "internaldrive",
                        isScanning: model.isScanning,
                        action: { Task { await scanLargeFiles() } }
                    )
                } else {
                    filterBar
                    Divider()

                    itemsList

                    if !filteredItems.isEmpty {
                        Divider()
                        footer
                    }
                }
            }
        }
        .onDisappear { model.cancelScan() }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 16) {
            // Size threshold
            HStack {
                Text("Min size:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $sizeThreshold) {
                    Text("50 MB").tag(50.0)
                    Text("100 MB").tag(100.0)
                    Text("250 MB").tag(250.0)
                    Text("500 MB").tag(500.0)
                    Text("1 GB").tag(1024.0)
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            HStack {
                Text("Show:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $scanKind) {
                    ForEach(LargeFilesModule.ScanKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
            }

            // Category filter
            HStack {
                Text("Type:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $selectedCategory) {
                    Text("All").tag(nil as String?)
                    ForEach(categories.dropFirst(), id: \.self) { cat in
                        Text(cat).tag(cat as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            // Sort order
            HStack {
                Text("Sort:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $sortOrder) {
                    ForEach(CleanupSortOrder.largeFileCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            Spacer()

            Text("\(filteredItems.count) items • \(totalSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Files List

    private var itemsList: some View {
        List(selection: $model.selectedItems) {
            ForEach(filteredItems) { item in
                LargeFileRow(
                    item: item,
                    isSelected: model.selectedItems.contains(item.id),
                    onOpen: {
                        if item.type == .directory {
                            NSWorkspace.shared.open(item.path)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([item.path])
                        }
                    }
                )
                .tag(item.id)
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    // MARK: - Footer

    private var footer: some View {
        CleanupFooter(
            selectedCount: model.selectedItems.count,
            summary: "Will free \(selectedSize)",
            onSelectAll: { model.selectAll(filteredItems) },
            actionTitle: "Move to Trash",
            actionDisabled: model.selectedItems.isEmpty,
            onAction: { model.showingConfirmation = true }
        )
        .deleteConfirmation(
            "Move \(model.selectedItems.count) items to Trash?",
            isPresented: $model.showingConfirmation,
            confirmTitle: "Move to Trash",
            message: "This will move \(selectedSize) of files and folders to Trash. You can restore them from Trash if needed."
        ) {
            Task { await deleteSelected() }
        }
    }

    // MARK: - Actions

    private func scanLargeFiles() async {
        // Large Files starts with nothing selected (unlike the size/date lists that
        // select-all on completion).
        let thresholdBytes = Int64(sizeThreshold * 1_048_576)  // Convert MB to bytes
        let kind = scanKind
        await model.scan(
            selectAllOnCompletion: false,
            onError: { "Couldn't scan for large files: \($0.localizedDescription)" }
        ) {
            var module = LargeFilesModule()
            module.threshold = thresholdBytes
            module.scanKind = kind
            return try await module.scan()
        }
    }

    private func deleteSelected() async {
        let itemsToDelete = filteredItems.filter { model.selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. The aggregate DeletionGuard veto throws; per-item
        // SafetyChecker failures come back in result.errors and nothing is deleted
        // for those, so we must not blindly clear them from the list. This keeps
        // its own epilogue (blocked-path bookkeeping + a bespoke banner) rather
        // than the shared prune, so it does not use `model.clean`.
        let engine = ScanEngine()
        let result: CleanupResult
        do {
            result = try await engine.clean(items: itemsToDelete, dryRun: false, confirmedLargeDeletion: true)
        } catch {
            model.errorMessage = "Couldn't move files to Trash: \(error.localizedDescription)"
            return
        }

        // Only the items that actually deleted should leave the list. CleanupError
        // identifies a blocked item by its path, so keep those (they were never
        // deleted) and remove the rest. Surface a message when any were blocked.
        let blockedPaths = Set(result.errors.map(\.path))
        let deletedIDs = Set(itemsToDelete.filter { !blockedPaths.contains($0.path) }.map(\.id))

        model.items.removeAll { deletedIDs.contains($0.id) }
        model.selectedItems.subtract(deletedIDs)

        if blockedPaths.isEmpty {
            model.errorMessage = nil
        } else {
            let count = blockedPaths.count
            model.errorMessage = "\(count) item\(count == 1 ? "" : "s") couldn't be moved to Trash and were kept."
        }
    }

    // MARK: - Computed

    private var filteredItems: [CleanupItem] {
        var items = model.items

        // Filter by size
        let thresholdBytes = Int64(sizeThreshold * 1_048_576)
        items = items.filter { $0.size >= thresholdBytes }

        // Filter by scan kind
        switch scanKind {
        case .files:
            items = items.filter { $0.type == .file }
        case .folders:
            items = items.filter { $0.type == .directory }
        case .both:
            break
        }

        // Filter by category
        if let category = selectedCategory {
            items = items.filter { $0.moduleName == category }
        }

        return items.sorted(using: sortOrder)
    }

    private var totalSize: String {
        filteredItems.formattedTotalSize()
    }

    private var selectedSize: String {
        filteredItems.formattedTotalSize(selected: model.selectedItems)
    }
}

// MARK: - Large File Row

struct LargeFileRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            // File icon
            FileIconView(url: item.path)
                .frame(width: 40, height: 40)
        } content: {
            // File info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.moduleName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(categoryColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(categoryColor)

                    Text(item.path.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
        } trailing: {
            // Size and date
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(.headline)

                if let date = item.lastModified {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Open button
            Button {
                onOpen()
            } label: {
                Image(systemName: item.type == .directory ? "arrow.up.forward.app" : "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // Reveal in Finder
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var categoryColor: Color {
        switch item.moduleName {
        case "Folder": return .blue
        case "Video": return .purple
        case "Image": return .green
        case "Audio": return .orange
        case "Archive": return .yellow
        case "Disk Image": return .blue
        case "Document": return .red
        case "Code": return .cyan
        case "Application": return .pink
        default: return .gray
        }
    }
}

// MARK: - File Icon View

struct FileIconView: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    LargeFilesView()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}

#endif
