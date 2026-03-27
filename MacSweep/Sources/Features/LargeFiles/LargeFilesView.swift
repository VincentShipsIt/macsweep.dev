import SwiftUI
import AppKit

/// View for finding and managing large files
struct LargeFilesView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var largeItems: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false

    // Filters
    @State private var sizeThreshold: Double = 100  // MB
    @State private var scanKind: LargeFilesModule.ScanKind = .both
    @State private var selectedCategory: String? = nil
    @State private var sortOrder: SortOrder = .sizeDesc

    enum SortOrder: String, CaseIterable {
        case sizeDesc = "Largest First"
        case sizeAsc = "Smallest First"
        case dateDesc = "Newest First"
        case dateAsc = "Oldest First"
        case nameAsc = "Name A-Z"
    }

    private let categories = ["All", "Folder", "Video", "Image", "Audio", "Archive", "Disk Image", "Document", "Code", "Application", "Other"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()

            if isScanning {
                scanningView
            } else if largeItems.isEmpty {
                emptyState
            } else {
                itemsList
            }

            if !filteredItems.isEmpty && !isScanning {
                Divider()
                footer
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Large & Old Files")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Find large files and folders by size and recent activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await scanLargeFiles()
                }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
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
                    ForEach(SortOrder.allCases, id: \.self) { order in
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

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning for large files...")
                .font(.headline)

            Text("This may take a moment")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No large items found")
                .font(.headline)

            Text("Run a scan to find items over \(Int(sizeThreshold)) MB")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Start Scan") {
                Task {
                    await scanLargeFiles()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Files List

    private var itemsList: some View {
        List(selection: $selectedItems) {
            ForEach(filteredItems) { item in
                LargeFileRow(
                    item: item,
                    isSelected: selectedItems.contains(item.id),
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
                selectedItems = Set(filteredItems.map(\.id))
            }
            .buttonStyle(.bordered)

            Button("Move to Trash") {
                showingConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Move \(selectedItems.count) items to Trash?",
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
            Text("This will move \(selectedSize) of files and folders to Trash. You can restore them from Trash if needed.")
        }
    }

    // MARK: - Actions

    private func scanLargeFiles() async {
        isScanning = true
        largeItems = []
        selectedItems = []

        defer { isScanning = false }

        var module = LargeFilesModule()
        module.threshold = Int64(sizeThreshold * 1_048_576)  // Convert MB to bytes
        module.scanKind = scanKind

        do {
            largeItems = try await module.scan()
        } catch {
            print("Scan error: \(error)")
        }
    }

    private func deleteSelected() async {
        let itemsToDelete = filteredItems.filter { selectedItems.contains($0.id) }
        var module = LargeFilesModule()
        module.scanKind = scanKind

        _ = try? await module.clean(items: itemsToDelete, dryRun: false)

        // Remove deleted items from list
        largeItems.removeAll { selectedItems.contains($0.id) }
        selectedItems.removeAll()
    }

    // MARK: - Computed

    private var filteredItems: [CleanupItem] {
        var items = largeItems

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

        // Sort
        switch sortOrder {
        case .sizeDesc:
            items.sort { $0.size > $1.size }
        case .sizeAsc:
            items.sort { $0.size < $1.size }
        case .dateDesc:
            items.sort { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .dateAsc:
            items.sort { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        case .nameAsc:
            items.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        }

        return items
    }

    private var totalSize: String {
        let total = filteredItems.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var selectedSize: String {
        let total = filteredItems
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Large File Row

struct LargeFileRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            // File icon
            FileIconView(url: item.path)
                .frame(width: 40, height: 40)

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

            Spacer()

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
        .padding(.vertical, 4)
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

#Preview {
    LargeFilesView()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}
