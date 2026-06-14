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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()

            if isScanning {
                scanningView
            } else if attachments.isEmpty {
                emptyState
            } else {
                attachmentsList
            }

            if !filteredAttachments.isEmpty && !isScanning {
                Divider()
                footer
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mail Attachments")
                    .font(.title)
                    .fontWeight(.bold)

                if let stats = stats {
                    Text("\(stats.totalAttachments) attachments • \(stats.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task {
                    await scanAttachments()
                }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .glassButton(prominent: true)
            .disabled(isScanning)
        }
        .padding()
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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Mail Attachments Found")
                .font(.headline)

            Text("Scan to find downloaded email attachments")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Start Scan") {
                Task {
                    await scanAttachments()
                }
            }
            .glassButton(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning mail attachments...")
                .font(.headline)

            Text("Checking Apple Mail, Outlook, Spark, and more")
                .font(.caption)
                .foregroundStyle(.secondary)
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

                Text("Will free \(selectedSize)")
                    .font(.headline)
            }

            Spacer()

            Button("Select All") {
                selectedItems = Set(filteredAttachments.map(\.id))
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
            "Move \(selectedItems.count) Attachments to Trash?",
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
            Text("This will move \(selectedSize) of mail attachments to Trash. The original emails will not be affected.")
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
        do {
            _ = try await engine.clean(items: itemsToDelete, dryRun: false)
        } catch {
            print("Mail attachments cleanup error: \(error)")
        }

        // Refresh
        attachments.removeAll { selectedItems.contains($0.id) }
        selectedItems.removeAll()
        stats = MailStats.from(items: attachments)
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
        let total = filteredAttachments.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var selectedSize: String {
        let total = filteredAttachments
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Attachment Row

struct AttachmentRow: View {
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

            Spacer()

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
        .padding(.vertical, 4)
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
