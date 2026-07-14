import SwiftUI
import AppKit

/// View for reclaiming local storage from cloud providers.
struct CloudCleanupView: View {
    @StateObject private var model = ScanFeatureModel()
    @State private var selectedProvider: String? = nil
    @State private var sortOrder: CleanupSortOrder = .sizeDesc

    private var providers: [String] {
        let names = Set(model.items.map { providerName(for: $0.moduleName) })
        return names.sorted()
    }

    var body: some View {
        FeaturePageShell(
            title: "Cloud Cleanup",
            subtitle: "Evict stale cloud downloads and provider caches.",
            trailing: model.items.isEmpty ? nil : AnyView(
                RescanButton(isScanning: model.isScanning, usesNativeToolbarStyle: true) { Task { await scanCloudStorage() } }
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
                        icon: "icloud",
                        title: "Scan Cloud Storage",
                        description: "Find stale local cloud copies and oversized provider cache folders you can reclaim.",
                        ctaTitle: "Scan Cloud Storage",
                        benefits: [
                            ScanBenefit("icloud.and.arrow.down", "Reclaims synced storage", "Evicts stale local copies of iCloud and provider files so they stay in the cloud, not on your disk."),
                            ScanBenefit("externaldrive.badge.icloud", "Clears provider caches", "Removes oversized cloud cache folders left behind by sync clients while your files stay safe online."),
                        ],
                        illustration: "icloud.and.arrow.down",
                        isScanning: model.isScanning,
                        action: { Task { await scanCloudStorage() } }
                    )
                    .transition(.scanCrossfade)
                } else {
                    Group {
                    filterBar
                    Divider()
                    itemsList

                    if !filteredItems.isEmpty {
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
        .onDisappear { model.cancelScan() }
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
                    ForEach(CleanupSortOrder.standardCases, id: \.self) { order in
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
        List(selection: $model.selectedItems) {
            ForEach(filteredItems) { item in
                CloudCleanupRow(item: item, isSelected: model.selectedItems.contains(item.id))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var footer: some View {
        CleanupFooter(
            selectedCount: model.selectedItems.count,
            summary: "Will reclaim \(selectedSize)",
            onSelectAll: { model.selectAll(filteredItems) },
            actionTitle: "Reclaim Space",
            actionTint: nil,
            actionDisabled: model.selectedItems.isEmpty,
            onAction: { model.showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $model.showingConfirmation,
            items: selectedCloudItems,
            disposition: .localCloudCopy,
            onConfirm: { await cleanSelected() }
        )
    }

    private func scanCloudStorage() async {
        await model.scan(onError: { "Couldn't scan cloud storage: \($0.localizedDescription)" }) {
            try await CloudCleanupModule().scan()
        }
    }

    private func cleanSelected() async -> CleanupResult? {
        // The shared model routes through ScanEngine (per-item SafetyChecker +
        // aggregate DeletionGuard cap), then prunes only the items that left disk.
        await model.clean(selectedCloudItems) { "Couldn't reclaim cloud space: \($0.localizedDescription)" }
    }

    private var filteredItems: [CleanupItem] {
        var items = model.items

        if let selectedProvider {
            items = items.filter { providerName(for: $0.moduleName) == selectedProvider }
        }

        return items.sorted(using: sortOrder)
    }

    private var totalSize: String {
        filteredItems.formattedTotalSize()
    }

    private var selectedSize: String {
        filteredItems.formattedTotalSize(selected: model.selectedItems)
    }

    private var selectedCloudItems: [CleanupItem] {
        filteredItems.filter { model.selectedItems.contains($0.id) }
    }

    private func providerName(for moduleName: String) -> String {
        moduleName.components(separatedBy: " ").first ?? "Cloud"
    }
}

private struct CloudCleanupRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            Image(systemName: item.moduleName.contains("Local Copy") ? "icloud.and.arrow.down" : "externaldrive.badge.icloud")
                .foregroundStyle(item.moduleName.contains("Local Copy") ? .cyan : .blue)
                .frame(width: 22)
        } content: {
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
        } trailing: {
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
    }
}

#if !SWIFT_PACKAGE
#Preview {
    CloudCleanupView()
        .frame(width: 760, height: 540)
}

#endif
