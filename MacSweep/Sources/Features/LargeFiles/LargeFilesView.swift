import SwiftUI
import AppKit

/// View for finding and managing large files
struct LargeFilesView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var largeFiles: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false

    // Filters
    @State private var sizeThreshold: Double = 100  // MB
    @State private var selectedCategory: String? = nil
    @State private var sortOrder: SortOrder = .sizeDesc

    enum SortOrder: String, CaseIterable {
        case sizeDesc = "Largest First"
        case sizeAsc = "Smallest First"
        case dateDesc = "Newest First"
        case dateAsc = "Oldest First"
        case nameAsc = "Name A-Z"
    }

    private let categories = ["All", "Video", "Image", "Audio", "Archive", "Disk Image", "Document", "Other"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()

            if isScanning {
                scanningView
            } else if largeFiles.isEmpty {
                emptyState
            } else {
                filesList
            }

            if !filteredFiles.isEmpty && !isScanning {
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

                Text("Find files consuming disk space")
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

            Text("\(filteredFiles.count) files • \(totalSize)")
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

            Text("No large files found")
                .font(.headline)

            Text("Run a scan to find files over \(Int(sizeThreshold)) MB")
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

    private var filesList: some View {
        List(selection: $selectedItems) {
            ForEach(filteredFiles) { item in
                LargeFileRow(
                    item: item,
                    isSelected: selectedItems.contains(item.id),
                    onPreview: {
                        // Open in Finder for preview
                        NSWorkspace.shared.activateFileViewerSelecting([item.path])
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
                selectedItems = Set(filteredFiles.map(\.id))
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
            "Move \(selectedItems.count) files to Trash?",
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
            Text("This will move \(selectedSize) of files to Trash. You can restore them from Trash if needed.")
        }
    }

    // MARK: - Actions

    private func scanLargeFiles() async {
        isScanning = true
        largeFiles = []
        selectedItems = []

        defer { isScanning = false }

        var module = LargeFilesModule()
        module.threshold = Int64(sizeThreshold * 1_048_576)  // Convert MB to bytes

        do {
            largeFiles = try await module.scan()
        } catch {
            print("Scan error: \(error)")
        }
    }

    private func deleteSelected() async {
        let itemsToDelete = filteredFiles.filter { selectedItems.contains($0.id) }
        let module = LargeFilesModule()

        _ = try? await module.clean(items: itemsToDelete, dryRun: false)

        // Remove deleted items from list
        largeFiles.removeAll { selectedItems.contains($0.id) }
        selectedItems.removeAll()
    }

    // MARK: - Computed

    private var filteredFiles: [CleanupItem] {
        var files = largeFiles

        // Filter by size
        let thresholdBytes = Int64(sizeThreshold * 1_048_576)
        files = files.filter { $0.size >= thresholdBytes }

        // Filter by category
        if let category = selectedCategory {
            files = files.filter { $0.moduleName == category }
        }

        // Sort
        switch sortOrder {
        case .sizeDesc:
            files.sort { $0.size > $1.size }
        case .sizeAsc:
            files.sort { $0.size < $1.size }
        case .dateDesc:
            files.sort { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .dateAsc:
            files.sort { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        case .nameAsc:
            files.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        }

        return files
    }

    private var totalSize: String {
        let total = filteredFiles.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var selectedSize: String {
        let total = filteredFiles
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

// MARK: - Large File Row

struct LargeFileRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let onPreview: () -> Void

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
                    Text(date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Preview button
            Button {
                onPreview()
            } label: {
                Image(systemName: "eye")
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
        case "Video": return .purple
        case "Image": return .green
        case "Audio": return .orange
        case "Archive": return .yellow
        case "Disk Image": return .blue
        case "Document": return .red
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
