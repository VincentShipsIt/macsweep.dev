import SwiftUI

/// View for managing mail attachments
struct MailAttachmentsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var attachments: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var stats: MailStats?
    @State private var filterSource: String? = nil
    @State private var filterType: String? = nil
    @State private var sizeThreshold: Double = 1  // MB
    @State private var errorMessage: String?

    var body: some View {
        FeaturePageShell(
            title: "Mail Attachments",
            subtitle: "Reclaim space from downloaded email attachments.",
            trailing: attachments.isEmpty ? nil : AnyView(
                RescanButton(isScanning: isScanning) { Task { await scanAttachments() } }
            ),
            hidesChrome: attachments.isEmpty,
            scrolls: attachments.isEmpty
        ) {
            if attachments.isEmpty {
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
                    isScanning: isScanning,
                    scanningMessage: "Scanning mail attachments",
                    action: { Task { await scanAttachments() } }
                )
            } else {
                filterBar
                Divider()
                attachmentsList

                if !filteredAttachments.isEmpty {
                    Divider()
                    footer
                }
            }
        }
        .errorAlert("Couldn't delete attachments", message: $errorMessage)
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
        List(selection: $selectedItems) {
            ForEach(filteredAttachments) { item in
                AttachmentRow(item: item, isSelected: selectedItems.contains(item.id))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    // MARK: - Footer

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedItems.count,
            summary: "Will free \(selectedSize)",
            onSelectAll: { selectedItems = Set(filteredAttachments.map(\.id)) },
            actionTitle: "Move to Trash",
            actionDisabled: selectedItems.isEmpty,
            onAction: { showingConfirmation = true }
        )
        .deleteConfirmation(
            "Move \(selectedItems.count) Attachments to Trash?",
            isPresented: $showingConfirmation,
            confirmTitle: "Move to Trash",
            message: "This will move \(selectedSize) of mail attachments to Trash. The original emails will not be affected."
        ) {
            Task { await deleteSelected() }
        }
    }

    // MARK: - Actions

    private func scanAttachments() async {
        isScanning = true
        attachments = []
        selectedItems = []

        defer { isScanning = false }

        var module = MailAttachmentsModule()
        module.threshold = Int64(sizeThreshold * 1_048_576)

        attachments = (try? await module.scan()) ?? []
        stats = MailStats.from(items: attachments)
    }

    private func deleteSelected() async {
        let itemsToDelete = filteredAttachments.filter { selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        let engine = ScanEngine()
        let result: CleanupResult
        do {
            result = try await engine.clean(items: itemsToDelete, dryRun: false, confirmedLargeDeletion: true)
        } catch {
            // The whole operation failed (e.g. deletion cap) — surface it and keep
            // every item, since nothing was removed.
            errorMessage = "Couldn't move attachments to Trash: \(error.localizedDescription)"
            return
        }

        // Per-item failures come back in result.errors (not thrown). Only drop
        // the items that actually left disk; keep failed ones visible. Assign
        // unconditionally so a clean retry clears any stale error.
        let failedPaths = Set(result.errors.map(\.path))
        attachments.removeAll { selectedItems.contains($0.id) && !failedPaths.contains($0.path) }
        selectedItems = selectedItems.filter { id in attachments.contains(where: { $0.id == id }) }
        stats = MailStats.from(items: attachments)
        errorMessage = result.failureSummaryMessage
    }

    // MARK: - Computed

    private var filteredAttachments: [CleanupItem] {
        var result = attachments

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
        filteredAttachments.formattedTotalSize(selected: selectedItems)
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
                    // Source badge
                    let source = item.moduleName.split(separator: " - ").first.map(String.init) ?? ""
                    Text(source)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(sourceColor(source).opacity(0.2), in: Capsule())
                        .foregroundStyle(sourceColor(source))

                    // Type badge
                    let type = item.moduleName.split(separator: " - ").last.map(String.init) ?? ""
                    Text(type)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(typeColor(type).opacity(0.2), in: Capsule())
                        .foregroundStyle(typeColor(type))

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
