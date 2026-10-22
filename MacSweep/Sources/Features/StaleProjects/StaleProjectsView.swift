import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manual project review; whole checkouts never enter Smart Care or generic artifact cleanup.
struct StaleProjectsView: View {
    @AppStorage("staleProjectMonths") private var staleMonths = 6
    @AppStorage("staleProjectRoots") private var storedRoots = "[]"
    @State private var inventory = StaleProjectInventory()
    @State private var selected = Set<UUID>()
    @State private var sort = ProjectSort.artifacts
    @State private var isWorking = false
    @State private var task: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var archivePlan: StaleProjectArchivePlan?
    @State private var receipt: StaleArchiveReceipt?
    @State private var showingSweep = false
    @State private var showingTrash = false
    @State private var records: [StaleProjectActionRecord] = []

    private let isSnapshot: Bool

    init(snapshotInventory: StaleProjectInventory? = nil) {
        isSnapshot = snapshotInventory != nil
        _inventory = State(initialValue: snapshotInventory ?? StaleProjectInventory())
    }

    private enum ProjectSort: String, CaseIterable {
        case artifacts = "Artifacts"
        case total = "Total size"
        case activity = "Last activity"
        case name = "Name"
    }

    private var roots: [URL] {
        if isSnapshot { return [URL(fileURLWithPath: "/Users/you/Projects")] }
        let paths = (try? JSONDecoder().decode([String].self, from: Data(storedRoots.utf8))) ?? []
        return paths.isEmpty
            ? [FileManager.default.homeDirectoryForCurrentUser]
            : paths
                .map { URL(fileURLWithPath: $0) }
    }

    private var service: StaleProjectsService {
        var service = StaleProjectsService()
        service.searchPaths = roots
        service.policy.staleMonths = staleMonths
        return service
    }

    private var selectedArtifacts: [CleanupItem] {
        inventory.projects.flatMap(\.eligibleArtifacts).filter { selected.contains($0.id) }
    }

    private var projects: [StaleProject] {
        inventory.projects.sorted {
            switch sort {
            case .artifacts: $0.artifactBytes > $1.artifactBytes
            case .total: ($0.totalBytes ?? -1) > ($1.totalBytes ?? -1)
            case .activity: ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast)
            case .name:
                $0.path.lastPathComponent
                    .localizedStandardCompare($1.path.lastPathComponent) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let errorMessage {
                MacSweepErrorBanner(message: errorMessage) { self.errorMessage = nil }
            }
            if isWorking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Inspecting project safety and contents…").font(.caption)
                    Spacer()
                    Button("Cancel") { task?.cancel() }
                }.padding()
            }
            content
            footer
        }
        .task {
            guard !isSnapshot else { return }
            task = Task { await scan() }
            await task?.value
        }
        .onDisappear { task?.cancel() }
        .sheet(item: $archivePlan) { plan in
            StaleProjectArchiveReview(plan: plan) {
                archivePlan = nil
                task = Task { await createArchive(plan) }
            }
        }
        .cleanupReview(
            isPresented: $showingTrash, items: [], disposition: .trash,
            note: "Move the complete checkout to Trash after verifying its unchanged backup, clean/pushed Git "
                + "state, protections and current activity. The ZIP stays at the selected destination. "
                + "Linked worktrees and unknown states stay retained. Trash does not immediately free disk space.",
            additionalCount: receipt == nil ? 0 : 1, additionalBytes: receipt?.manifest.allocatedBytes,
            additionalModules: ["Archived checkout"], additionalPaths: receipt.map { [$0.project.path] } ?? [],
            onConfirm: trashCheckout,
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stale Projects").font(.title).bold()
                    Text("Review generated artifacts, archive source, then separately review checkout Trash.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan", systemImage: "magnifyingglass") { task = Task { await scan() } }
                    .glassButton(prominent: true).disabled(isWorking)
            }
            HStack {
                Picker("Stale after", selection: $staleMonths) {
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("12 months").tag(12)
                }.frame(width: 220)
                Picker("Sort", selection: $sort) {
                    ForEach(ProjectSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 220)
                Spacer()
                Button("Choose Roots…", action: chooseRoots).disabled(isWorking)
            }
            Text(
                "Roots: " + roots.map(\.path).joined(separator: ", ")
                    + ". Home scans include supported agent worktree homes. Discovery has depth, entry and time limits."
            )
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding().background(MacSweepTheme.panelStrong)
            .onChange(of: staleMonths) {
                selected = []
                inventory = .init()
            }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(inventory.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if inventory.projects.isEmpty, !isWorking {
                    ContentUnavailableView(
                        "No Projects Found", systemImage: "folder.badge.questionmark",
                        description: Text(
                            "Choose developer roots, then scan to inspect repositories.",
                        ))
                }
                if let receipt {
                    archiveResult(receipt)
                }
                ForEach(projects) { project in
                    StaleProjectRow(project: project, selected: $selected, disabled: isWorking) {
                        chooseArchive(project)
                    }
                }
                if !records.isEmpty {
                    StaleProjectHistoryPanel(records: records)
                }
            }.padding()
        }
    }

    private var footer: some View {
        CleanupFooter(
            selectedCount: selectedArtifacts.count,
            summary: "Only selected verified artifacts move to Trash. Source and checkout actions are separate.",
            onSelectAll: { selected = Set(inventory.projects.flatMap(\.eligibleArtifacts).map(\.id)) },
            actionTitle: "Review Artifact Sweep", actionDisabled: selectedArtifacts.isEmpty || isWorking,
            onAction: { showingSweep = true },
        )
        .cleanupReview(
            isPresented: $showingSweep, items: selectedArtifacts, disposition: .trash,
            note: "Generated artifacts only. Source, configurations, lockfiles, captures and conversations stay. "
                + "Each target is rechecked through shared content, Git, protection and live-job gates. "
                + "Age and Git dirty flags do not authorize artifact removal. "
                + "No exclusive disk-space recovery is claimed.",
            onConfirm: sweep,
        )
    }

    private func archiveResult(_ receipt: StaleArchiveReceipt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Verified ZIP: " + receipt.destination.lastPathComponent, systemImage: "checkmark.shield")
                .font(.headline)
            Text(receipt.destination.path).font(.caption).textSelection(.enabled)
            Text("Archive size: " + receipt.archiveBytes.formattedFileSize + ". Source is still in place.")
                .font(.caption)
            if let blocker = receipt.trashBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            Button("Review Checkout Trash", systemImage: "trash") { showingTrash = true }
                .disabled(isWorking || receipt.trashBlocker != nil)
        }.padding().macSweepCard()
    }

    private func scan() async {
        guard !isWorking else { return }
        isWorking = true
        selected = []
        errorMessage = nil
        defer {
            isWorking = false
            records = service.history.history()
        }
        do { inventory = try await service.inventory() } catch { errorMessage = error.localizedDescription }
    }

    private func sweep() async -> CleanupResult? {
        isWorking = true
        let result = await service.sweep(selectedArtifacts)
        selected = []
        isWorking = false
        await scan()
        return result
    }

    private func createArchive(_ plan: StaleProjectArchivePlan) async {
        isWorking = true
        errorMessage = nil
        defer {
            isWorking = false
            records = service.history.history()
        }
        do { receipt = try await service.createArchive(plan.project, destination: plan.destination) } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func trashCheckout() async -> CleanupResult? {
        guard let receipt else { return nil }
        isWorking = true
        let result = await service.trashCheckout(receipt)
        if result.itemsProcessed > 0 {
            self.receipt = nil
        }
        isWorking = false
        await scan()
        return result
    }

    private func chooseRoots() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use Roots"
        guard panel.runModal() == .OK, !panel.urls.isEmpty,
            let data = try? JSONEncoder().encode(panel.urls.map { $0.resolvingSymlinksInPath().path }),
            let text = String(data: data, encoding: .utf8)
        else { return }
        storedRoots = text
        task = Task { await scan() }
    }

    private func chooseArchive(_ project: StaleProject) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = project.path.lastPathComponent + "-archive.zip"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        archivePlan = StaleProjectArchivePlan(project: project, destination: destination)
    }
}
