import SwiftUI
import AppKit

/// View for reclaiming local storage from cloud providers.
struct CloudCleanupView: View {
    @State private var isScanning = false
    @State private var cloudItems: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var selectedProvider: String? = nil
    @State private var sortOrder: SortOrder = .sizeDesc
    @State private var errorMessage: String?

    enum SortOrder: String, CaseIterable {
        case sizeDesc = "Largest First"
        case dateAsc = "Oldest First"
        case dateDesc = "Newest First"
        case nameAsc = "Name A-Z"
    }

    private var providers: [String] {
        let names = Set(cloudItems.map { providerName(for: $0.moduleName) })
        return names.sorted()
    }

    var body: some View {
        FeaturePageShell(
            title: "Cloud Cleanup",
            subtitle: "Evict stale cloud downloads and provider caches.",
            trailing: cloudItems.isEmpty ? nil : AnyView(
                Button {
                    Task { await scanCloudStorage() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(isScanning)
            ),
            scrolls: cloudItems.isEmpty
        ) {
            VStack(spacing: 0) {
                if let errorMessage {
                    errorBanner(errorMessage)
                }

                if cloudItems.isEmpty {
                    ScanLandingView(
                        icon: "icloud",
                        title: "Scan Cloud Storage",
                        description: "Find stale local cloud copies and oversized provider cache folders you can reclaim.",
                        ctaTitle: "Scan Cloud Storage",
                        benefits: [
                            ScanBenefit("icloud.and.arrow.down", "Reclaims synced storage", "Evicts stale local copies of iCloud and provider files so they stay in the cloud, not on your disk."),
                            ScanBenefit("externaldrive.badge.icloud", "Clears provider caches", "Removes oversized cloud cache folders left behind by sync clients while your files stay safe online."),
                        ],
                        illustration: "icloud.and.arrow.down",
                        isScanning: isScanning,
                        action: { Task { await scanCloudStorage() } }
                    )
                } else {
                    filterBar
                    Divider().overlay(MacSweepTheme.divider)
                    itemsList

                    if !filteredItems.isEmpty {
                        Divider().overlay(MacSweepTheme.divider)
                        footer
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            Text(message).font(.caption)
            Spacer()
            Button { errorMessage = nil } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }

    private var filterBar: some View {
        HStack(spacing: 16) {
            HStack {
                Text("Provider:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $selectedProvider) {
                    Text("All").tag(nil as String?)
                    ForEach(providers, id: \.self) { provider in
                        Text(provider).tag(provider as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }

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

            Text("\(filteredItems.count) items • \(totalSize) recoverable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var itemsList: some View {
        List(selection: $selectedItems) {
            ForEach(filteredItems) { item in
                CloudCleanupRow(item: item, isSelected: selectedItems.contains(item.id))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(selectedItems.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Will reclaim \(selectedSize)")
                    .font(.headline)
            }

            Spacer()

            Button("Select All") {
                selectedItems = Set(filteredItems.map(\.id))
            }
            .glassButton()

            Button("Reclaim Space") {
                showingConfirmation = true
            }
            .glassButton(prominent: true)
            .disabled(selectedItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Reclaim \(selectedItems.count) cloud items?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reclaim Space", role: .destructive) {
                Task { await cleanSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local cloud copies will be evicted when possible, and cloud cache folders will be moved to Trash.")
        }
    }

    private func scanCloudStorage() async {
        isScanning = true
        cloudItems = []
        selectedItems = []
        errorMessage = nil
        defer { isScanning = false }

        do {
            let module = CloudCleanupModule()
            cloudItems = try await module.scan()
            selectedItems = Set(cloudItems.map(\.id))
        } catch {
            errorMessage = "Couldn't scan cloud storage: \(error.localizedDescription)"
        }
    }

    private func cleanSelected() async {
        let itemsToClean = filteredItems.filter { selectedItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        let engine = ScanEngine()
        let result: CleanupResult
        do {
            result = try await engine.clean(items: itemsToClean, dryRun: false)
        } catch {
            errorMessage = "Couldn't reclaim cloud space: \(error.localizedDescription)"
            return
        }
        // Per-item safety failures come back in result.errors (not thrown). Only
        // drop the items that actually left disk; keep blocked ones visible.
        let blockedPaths = Set(result.errors.map(\.path))
        cloudItems.removeAll { selectedItems.contains($0.id) && !blockedPaths.contains($0.path) }
        selectedItems = selectedItems.filter { id in cloudItems.contains(where: { $0.id == id }) }
        errorMessage = blockedPaths.isEmpty
            ? nil
            : "\(blockedPaths.count) item(s) couldn't be removed (blocked by safety checks)."
    }

    private var filteredItems: [CleanupItem] {
        var items = cloudItems

        if let selectedProvider {
            items = items.filter { providerName(for: $0.moduleName) == selectedProvider }
        }

        switch sortOrder {
        case .sizeDesc:
            items.sort { $0.size > $1.size }
        case .dateAsc:
            items.sort { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        case .dateDesc:
            items.sort { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .nameAsc:
            items.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        }

        return items
    }

    private var totalSize: String {
        ByteCountFormatter.string(fromByteCount: filteredItems.reduce(0) { $0 + $1.size }, countStyle: .file)
    }

    private var selectedSize: String {
        ByteCountFormatter.string(
            fromByteCount: filteredItems.filter { selectedItems.contains($0.id) }.reduce(0) { $0 + $1.size },
            countStyle: .file
        )
    }

    private func providerName(for moduleName: String) -> String {
        moduleName.components(separatedBy: " ").first ?? "Cloud"
    }
}

private struct CloudCleanupRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            Image(systemName: item.moduleName.contains("Local Copy") ? "icloud.and.arrow.down" : "externaldrive.badge.icloud")
                .foregroundStyle(item.moduleName.contains("Local Copy") ? .cyan : .blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)

                Text(item.moduleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(item.path.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.formattedSize)
                    .font(.headline)

                if let date = item.lastModified {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
}

#if !SWIFT_PACKAGE
#Preview {
    CloudCleanupView()
        .frame(width: 760, height: 540)
}

#endif
