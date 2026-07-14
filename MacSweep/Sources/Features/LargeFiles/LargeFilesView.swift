import SwiftUI
import AppKit
import QuickLook

/// View for finding and managing large files
struct LargeFilesView: View {
    @StateObject private var model = ScanFeatureModel()

    // Filters
    @State private var sizeThreshold: Double = 100  // MB
    @State private var scanKind: LargeFilesModule.ScanKind = .both
    @State private var selectedCategory: String?
    @State private var ageFilter: LargeFilesModule.ActivityAge = .any
    @State private var sortOrder: CleanupSortOrder = .sizeDesc
    @State private var previewURL: URL?

    private let categories = [
        "All", "Folder", "Video", "Image", "Audio", "Archive", "Disk Image",
        "Document", "Code", "Application", "Other"
    ]

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
                RescanButton(isScanning: model.isScanning, usesNativeToolbarStyle: true) {
                    Task { await scanLargeFiles() }
                }
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
                            ScanBenefit(
                                "arrow.up.arrow.down.circle",
                                "Reclaim the most space fast",
                                "Ranks files and folders by size so the biggest space hogs surface first."
                            ),
                            ScanBenefit(
                                "clock.badge.questionmark",
                                "Surfaces forgotten files",
                                "Flags old videos, disk images, and archives you may no longer need."
                            )
                        ],
                        illustration: "internaldrive",
                        isScanning: model.isScanning,
                        action: { Task { await scanLargeFiles() } }
                    )
                } else {
                    ManualReviewNotice(
                        message: "Review-only results — large files and folders are never "
                            + "selected for automatic cleanup."
                    )
                    filterBar
                    Divider()

                    itemsList

                    if !filteredItems.isEmpty {
                        footer
                    }
                }
            }
        }
        .quickLookPreview($previewURL)
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
                Text("Age:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $ageFilter) {
                    ForEach(LargeFilesModule.ActivityAge.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
            }

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
                    onPreview: { previewURL = item.path }
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
        .cleanupReview(
            isPresented: $model.showingConfirmation,
            items: selectedLargeItems,
            disposition: .trash,
            note: "Large files are never selected for automatic cleanup; "
                + "this sheet reflects only your manual selection.",
            onConfirm: { await deleteSelected() }
        )
    }

    // MARK: - Actions

    private func scanLargeFiles() async {
        // Large Files starts with nothing selected (unlike the size/date lists that
        // select-all on completion).
        let thresholdBytes = Int64(sizeThreshold * 1_048_576)  // Convert MB to bytes
        let kind = scanKind
        await model.scan(
            selectAllOnCompletion: false,
            onError: { "Couldn't scan for large files: \($0.localizedDescription)" },
            {
                var module = LargeFilesModule()
                module.threshold = thresholdBytes
                module.scanKind = kind
                return try await module.scan()
            }
        )
    }

    private func deleteSelected() async -> CleanupResult? {
        await model.clean(selectedLargeItems) { "Couldn't move files to Trash: \($0.localizedDescription)" }
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

        if let cutoff = ageFilter.cutoffDate() {
            items = items.filter { item in
                guard let activityDate = item.lastModified else { return false }
                return activityDate < cutoff
            }
        }

        return items.sorted(using: sortOrder)
    }

    private var totalSize: String {
        filteredItems.formattedTotalSize()
    }

    private var selectedSize: String {
        filteredItems.formattedTotalSize(selected: model.selectedItems)
    }

    private var selectedLargeItems: [CleanupItem] {
        filteredItems.filter { model.selectedItems.contains($0.id) }
    }
}

// MARK: - Large File Row

struct LargeFileRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let onPreview: () -> Void

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

            Button(action: onPreview) {
                Image(systemName: "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quick Look")
            .accessibilityLabel("Preview \(item.displayName)")

            // Reveal in Finder
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.displayName) in Finder")
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

#if !SWIFT_PACKAGE
#Preview {
    LargeFilesView()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}

#endif
