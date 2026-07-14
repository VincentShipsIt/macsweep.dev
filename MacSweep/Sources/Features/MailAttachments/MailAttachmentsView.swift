import SwiftUI

/// View for managing mail attachments
struct MailAttachmentsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var model = ScanFeatureModel()
    @State private var filterSource: String? = nil
    @State private var filterType: String? = nil
    @State private var sizeThreshold: Double = 1  // MB

    /// Derived from the current results, so it always reflects the live list.
    private var stats: MailStats? { MailStats.from(items: model.items) }

    var body: some View {
        FeaturePageShell(
            title: "Mail Attachments",
            subtitle: "Reclaim space from downloaded email attachments.",
            trailing: model.items.isEmpty ? nil : AnyView(
                RescanButton(isScanning: model.isScanning, usesNativeToolbarStyle: true) { Task { await scanAttachments() } }
            ),
            hidesChrome: model.items.isEmpty,
            scrolls: model.items.isEmpty
        ) {
            Group {
            if model.items.isEmpty {
                ZStack(alignment: .top) {
                    ScanLandingView(
                        icon: "envelope",
                        title: "Scan for Mail Attachments",
                        description: "Find downloaded attachments across Apple Mail, Outlook, Spark, and more.",
                        ctaTitle: "Scan Mail Attachments",
                        benefits: [
                            ScanBenefit("tray.full", "Recovers buried space", "Surfaces large attachments downloaded across Apple Mail, Outlook, Spark, and Thunderbird so you can clear the heaviest ones first."),
                            ScanBenefit("envelope.badge.shield.half.filled", "Your emails stay intact", "Only the cached attachment files are removed. The original messages remain untouched and can re-download on demand."),
                        ],
                        illustration: "paperclip",
                        isScanning: model.isScanning,
                        scanningMessage: "Scanning mail attachments",
                        action: { Task { await scanAttachments() } }
                    )

                    if !appState.hasFullDiskAccess && !model.isScanning {
                        FullDiskAccessWarningBanner(scope: .mail)
                            .padding(20)
                    }
                }
                .transition(.scanCrossfade)
            } else {
                Group {
                if !appState.hasFullDiskAccess {
                    FullDiskAccessWarningBanner(scope: .mail)
                        .padding(.horizontal)
                        .padding(.top, 12)
                }
                filterBar
                Divider()
                attachmentsList

                if !filteredAttachments.isEmpty {
                    Divider()
                    footer
                }
                }
                .transition(.scanCrossfade)
            }
            }
            // Crossfade the landing ⇄ results swap (no-ops under Reduce Motion).
            .animated(.scanCrossfade, value: model.items.isEmpty)
        }
        .errorAlert("Couldn't delete attachments", message: $model.errorMessage)
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
                    Text("1 MB").tag(1.0)
                    Text("5 MB").tag(5.0)
                    Text("10 MB").tag(10.0)
                    Text("25 MB").tag(25.0)
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }

            // Source filter
            if let stats = stats, stats.bySource.count > 1 {
                HStack {
                    Text("Source:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $filterSource) {
                        Text("All").tag(nil as String?)
                        ForEach(Array(stats.bySource.keys.sorted()), id: \.self) { source in
                            Text(source).tag(source as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
            }

            // Type filter
            if let stats = stats, stats.byType.count > 1 {
                HStack {
                    Text("Type:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $filterType) {
                        Text("All").tag(nil as String?)
                        ForEach(Array(stats.byType.keys.sorted()), id: \.self) { type in
                            Text(type).tag(type as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
            }

            Spacer()

            Text("\(filteredAttachments.count) items • \(filteredSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Attachments List

    private var attachmentsList: some View {
        List(selection: $model.selectedItems) {
            ForEach(filteredAttachments) { item in
                AttachmentRow(item: item, isSelected: model.selectedItems.contains(item.id))
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
            onSelectAll: { model.selectAll(filteredAttachments) },
            actionTitle: "Move to Trash",
            actionDisabled: model.selectedItems.isEmpty,
            onAction: { model.showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $model.showingConfirmation,
            items: selectedAttachments,
            disposition: .trash,
            note: "The original email messages remain untouched and attachments can be downloaded again.",
            onConfirm: { await deleteSelected() }
        )
    }

    // MARK: - Actions

    private func scanAttachments() async {
        // Scan failures were swallowed here originally (via `try?`); keep that by
        // passing no error formatter, and start with nothing selected.
        let threshold = Int64(sizeThreshold * 1_048_576)
        await model.scan(selectAllOnCompletion: false, onError: nil) {
            var module = MailAttachmentsModule()
            module.threshold = threshold
            return try await module.scan()
        }
    }

    private func deleteSelected() async -> CleanupResult? {
        // The shared model routes through ScanEngine (per-item SafetyChecker +
        // aggregate DeletionGuard cap), then prunes only the items that left disk;
        // `stats` recomputes automatically from the pruned list.
        await model.clean(selectedAttachments) { "Couldn't move attachments to Trash: \($0.localizedDescription)" }
    }

    // MARK: - Computed

    private var filteredAttachments: [CleanupItem] {
        var result = model.items

        // Filter by size
        let thresholdBytes = Int64(sizeThreshold * 1_048_576)
        result = result.filter { $0.size >= thresholdBytes }

        // Filter by source
        if let source = filterSource {
            result = result.filter { $0.moduleName.hasPrefix(source) }
        }

        // Filter by type
        if let type = filterType {
            result = result.filter { $0.moduleName.hasSuffix(type) }
        }

        return result
    }

    private var filteredSize: String {
        filteredAttachments.formattedTotalSize()
    }

    private var selectedSize: String {
        filteredAttachments.formattedTotalSize(selected: model.selectedItems)
    }

    private var selectedAttachments: [CleanupItem] {
        filteredAttachments.filter { model.selectedItems.contains($0.id) }
    }
}

// MARK: - Attachment Row

struct AttachmentRow: View {
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
                    // Source badge — per-mail-client categorical color.
                    let source = item.moduleName.split(separator: " - ").first.map(String.init) ?? ""
                    TagBadge(source, tint: sourceColor(source))

                    // Type badge — per-file-type categorical color.
                    let type = item.moduleName.split(separator: " - ").last.map(String.init) ?? ""
                    TagBadge(type, tint: typeColor(type))

                    if let date = item.lastModified {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } trailing: {
            Text(item.formattedSize)
                .font(.headline)

            // Quick Look
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "Apple Mail": return .blue
        case "Microsoft Outlook": return .cyan
        case "Spark": return .orange
        case "Thunderbird": return .indigo
        default: return .gray
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "Documents": return .red
        case "Images": return .green
        case "Videos": return .purple
        case "Audio": return .orange
        case "Archives": return .yellow
        default: return .gray
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MailAttachmentsView()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}

#endif
