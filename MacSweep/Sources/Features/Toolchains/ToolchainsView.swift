import SwiftUI

/// Dedicated review-only surface. Toolchains never enter Smart Care or generic file cleanup.
struct ToolchainsView: View {
    @AppStorage("toolchainStaleMonths") private var staleMonths = 6
    @State private var inventory = ToolchainInventory()
    @State private var selected = Set<String>()
    @State private var isScanning = false
    @State private var didScan = false
    @State private var showingReview = false
    @State private var errorMessage: String?
    private let service: ToolchainService

    init(service: ToolchainService = .init(), snapshotInventory: ToolchainInventory? = nil) {
        self.service = service
        _inventory = State(initialValue: snapshotInventory ?? ToolchainInventory())
        _didScan = State(initialValue: snapshotInventory != nil)
    }

    private var policy: ToolchainPolicy { ToolchainPolicy(staleMonths: staleMonths) }
    private var selectedVersions: [ToolchainInstallation] {
        inventory.installations.filter { selected.contains($0.id) && $0.isSelectable }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let errorMessage {
                MacSweepErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }
            if isScanning {
                ProgressView("Inspecting toolchains, repository references and running jobs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
            if !inventory.installations.isEmpty && !isScanning { footer }
        }
        .onChange(of: staleMonths) {
            selected = []
            inventory = .init()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Toolchains").font(.title).fontWeight(.bold)
                    Text("Review old runtime versions using native manager uninstall commands.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan", systemImage: "magnifyingglass") { Task { await scan() } }
                    .glassButton(prominent: true).disabled(isScanning)
            }
            Picker("Stale after", selection: $staleMonths) {
                Text("3 months").tag(3)
                Text("6 months").tag(6)
                Text("12 months").tag(12)
            }.pickerStyle(.segmented)
            Text(
                "Age uses access and modification signals, which are imperfect. "
                    + "Active and unknown versions stay locked. Scan again after changing the threshold."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding().background(MacSweepTheme.panelStrong)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if inventory.installations.isEmpty {
                    ContentUnavailableView(
                        didScan ? "No Installed Toolchains Found" : "Review Installed Toolchains",
                        systemImage: "terminal",
                        description: Text(
                            didScan
                                ? "Supported managers appear when their installed versions are detected."
                                : "Scan to inspect versions, project references and running jobs before review."))
                }
                ForEach(inventory.issues, id: \.self) { issue in
                    Label(issue, systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(ToolchainManager.allCases, id: \.self) { manager in
                    let versions = inventory.installations.filter { $0.manager == manager }
                    if !versions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(manager.title).font(.headline)
                            ForEach(versions) { version in
                                ToolchainVersionRow(version: version, isSelected: selected.contains(version.id)) {
                                    if !selected.insert(version.id).inserted { selected.remove(version.id) }
                                }
                            }
                        }.padding().macSweepCard()
                    }
                }
                if !inventory.referenceRoots.isEmpty {
                    Text(
                        "Reference scope: " + inventory.referenceRoots.map(\.path).joined(separator: ", ")
                            + ". Library, Git metadata and caches are excluded. "
                            + "Installed runtimes are inspected for linked dependencies. "
                            + "External projects require manual review."
                    )
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding()
        }
    }

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedVersions.count, summary: "Native uninstall permanently removes selected versions.",
            onSelectAll: { selected = Set(inventory.installations.filter(\.isSelectable).map(\.id)) },
            actionTitle: "Review Uninstall", actionDisabled: selectedVersions.isEmpty,
            onAction: { showingReview = true }
        )
        .cleanupReview(
            isPresented: $showingReview, items: [], disposition: .permanent,
            note: selectedVersions.compactMap(\.command?.preview).joined(separator: "\n\n")
                + "\n\nRuntime and manager metadata are permanently removed. "
                + "Global packages inside a selected runtime are removed with it. Byte savings are unavailable.",
            additionalCount: selectedVersions.count, additionalBytes: nil, additionalModules: ["Toolchains"],
            additionalPaths: selectedVersions.map(\.path),
            onConfirm: {
                let result = await service.remove(selectedVersions, policy: policy)
                await scan()
                return result
            })
    }

    private func scan() async {
        isScanning = true
        selected = []
        errorMessage = nil
        defer {
            isScanning = false
            didScan = true
        }
        do { inventory = try await service.inventory(policy: policy) } catch {
            inventory = .init()
            errorMessage = error.localizedDescription
        }
    }
}

private struct ToolchainVersionRow: View {
    let version: ToolchainInstallation
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: toggle) {
                HStack {
                    Image(
                        systemName: version.isSelectable
                            ? (isSelected ? "checkmark.square.fill" : "square") : "lock.fill")
                    Text(version.tool + " " + version.version).fontWeight(.medium)
                    Text(version.status.rawValue.capitalized).foregroundStyle(.secondary)
                    Spacer()
                    Text(version.size?.formattedFileSize ?? "Size unavailable").foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).disabled(!version.isSelectable)
                .accessibilityLabel("\(version.tool) \(version.version), \(version.status.rawValue)")
            Text(version.path.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(version.evidence, id: \.self) { reason in
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let command = version.command {
                Text(command.preview).font(.caption.monospaced()).textSelection(.enabled)
            }
        }.padding(.vertical, 5)
    }
}
