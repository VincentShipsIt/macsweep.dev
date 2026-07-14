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
                RescanButton(isScanning: appState.isScanning, usesNativeToolbarStyle: true) {
                    Task { await appState.scan(modules: ["system-cache"]) }
                }
            ),
            hidesChrome: appState.scanResults.isEmpty,
            scrolls: appState.scanResults.isEmpty
        ) {
            Group {
            if appState.scanResults.isEmpty {
                ZStack(alignment: .top) {
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

                    if !appState.hasFullDiskAccess && !appState.isScanning {
                        FullDiskAccessWarningBanner(scope: .systemData)
                            .padding(20)
                    }
                }
                .transition(.scanCrossfade)
            } else {
                VStack(spacing: 0) {
                    if !appState.hasFullDiskAccess {
                        FullDiskAccessWarningBanner(scope: .systemData)
                            .padding(.horizontal)
                            .padding(.top, 12)
                    }

                    resultsList

                    footer
                }
                .transition(.scanCrossfade)
            }
            }
            // Crossfade the landing ⇄ results swap (no-ops under Reduce Motion).
            .animated(.scanCrossfade, value: appState.scanResults.isEmpty)
        }
        .errorAlert("Cleanup Failed", message: $appState.lastDeletionError)
    }

    // MARK: - Results List

    private var resultsList: some View {
        VStack(spacing: 0) {
            // Search field — selection now lives in the floating footer.
            HStack {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()
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
        CleanupFooter(
            selectedCount: appState.selectedItems.count,
            totalCount: appState.scanResults.count,
            summary: "Will free \(appState.selectedSize.formattedFileSize)",
            onSelectAll: { appState.selectAll() },
            actionTitle: "Clean",
            actionDisabled: appState.selectedItems.isEmpty,
            onAction: { showingConfirmation = true }
        )
        .cleanupReview(
            isPresented: $showingConfirmation,
            items: selectedResults,
            disposition: .mixed,
            note: "System caches use their module's declared Trash-first or permanent-cache action. "
                + "Protected paths are checked again immediately before execution.",
            onConfirm: { try? await appState.deleteSelected(confirmedLargeDeletion: true) }
        )
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

    private var selectedResults: [CleanupItem] {
        appState.scanResults.filter { appState.selectedItems.contains($0.id) }
    }
}

// MARK: - Cleanup Item Row

struct CleanupItemRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        SelectableItemRow(isSelected: isSelected) {
            Image(systemName: item.icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
        } content: {
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
        } trailing: {
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
