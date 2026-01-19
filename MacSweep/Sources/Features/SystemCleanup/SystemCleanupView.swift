import SwiftUI

/// View for system cleanup with scan results
struct SystemCleanupView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingConfirmation = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if appState.scanResults.isEmpty {
                emptyState
            } else {
                // Results list
                resultsList
            }

            // Footer with actions
            if !appState.scanResults.isEmpty {
                Divider()
                footer
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("System Cleanup")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Remove caches, logs, and temporary files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await appState.scan(modules: ["system-cache"])
                }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isScanning)
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            if appState.isScanning {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Scanning...")
                    .font(.headline)

                Text("Finding files that can be safely removed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)

                Text("No items found")
                    .font(.headline)

                Text("Run a scan to find junk files")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Start Scan") {
                    Task {
                        await appState.scan()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results List

    private var resultsList: some View {
        VStack(spacing: 0) {
            // Search and select all
            HStack {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                Button("Select All") {
                    appState.selectAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Button("Deselect All") {
                    appState.deselectAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Items list
            List(selection: $appState.selectedItems) {
                ForEach(filteredResults) { item in
                    CleanupItemRow(item: item, isSelected: appState.selectedItems.contains(item.id))
                        .tag(item.id)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(appState.selectedItems.count) of \(appState.scanResults.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Will free \(ByteCountFormatter.string(fromByteCount: appState.selectedSize, countStyle: .file))")
                    .font(.headline)
            }

            Spacer()

            Button("Preview") {
                // Show preview
            }
            .buttonStyle(.bordered)

            Button("Clean") {
                showingConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(appState.selectedItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Delete \(appState.selectedItems.count) items?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    _ = try? await appState.deleteSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will free \(ByteCountFormatter.string(fromByteCount: appState.selectedSize, countStyle: .file)). This action cannot be undone.")
        }
    }

    // MARK: - Filtered Results

    private var filteredResults: [CleanupItem] {
        if searchText.isEmpty {
            return appState.scanResults
        }
        return appState.scanResults.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.path.path.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Cleanup Item Row

struct CleanupItemRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            Image(systemName: item.icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)

                Text(item.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.formattedSize)
                    .font(.caption)
                    .fontWeight(.medium)

                if let date = item.lastModified {
                    Text(date, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    SystemCleanupView()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}
