import SwiftUI

/// View for system cleanup with scan results
struct SystemCleanupView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingConfirmation = false
    @State private var searchText = ""

    var body: some View {
        FeaturePageShell(
            title: "System Junk",
            subtitle: "Clear caches, logs, and temporary files.",
            trailing: appState.scanResults.isEmpty ? nil : AnyView(
                Button {
                    Task { await appState.scan(modules: ["system-cache"]) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(appState.isScanning)
            ),
            scrolls: appState.scanResults.isEmpty
        ) {
            if appState.scanResults.isEmpty {
                ScanLandingView(
                    icon: "sparkles",
                    title: "Scan for System Junk",
                    description: "Find reclaimable caches, logs, and temporary files across your system. Nothing is removed until you review and confirm what to clean.",
                    ctaTitle: "Scan System Junk",
                    benefits: [
                        ScanBenefit("speedometer", "Frees up disk space", "Removes reclaimable caches, logs, and leftover temporary files to give your Mac room to breathe."),
                        ScanBenefit("checkmark.shield", "Safe by default", "Nothing is deleted until you review the results and confirm what to clean."),
                    ],
                    illustration: "sparkles",
                    isScanning: appState.isScanning,
                    progress: appState.scanProgress,
                    scanningMessage: appState.currentScanModule,
                    action: { Task { await appState.scan(modules: ["system-cache"]) } }
                )
            } else {
                resultsList

                Divider()
                    .overlay(MacSweepTheme.divider)

                footer
            }
        }
        .alert(
            "Cleanup Failed",
            isPresented: Binding(
                get: { appState.lastDeletionError != nil },
                set: { if !$0 { appState.lastDeletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastDeletionError ?? "")
        }
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
            .macSweepListSurface()
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
            .glassButton()

            Button("Clean") {
                showingConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(appState.selectedItems.isEmpty)
        }
        .padding()
        .background(MacSweepTheme.panelStrong)
        .confirmationDialog(
            "Delete \(appState.selectedItems.count) items?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    // Behind this confirmation dialog → confirm the large-deletion gate.
                    _ = try? await appState.deleteSelected(confirmedLargeDeletion: true)
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

#if !SWIFT_PACKAGE
#Preview {
    SystemCleanupView()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}

#endif
