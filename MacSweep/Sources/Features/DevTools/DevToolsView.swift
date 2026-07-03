import SwiftUI

/// View for cleaning up developer artifacts
struct DevToolsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: DevToolsTab = .artifacts
    @State private var hasCompletedBuildArtifactScan = false
    @State private var isBuildArtifactScanRunning = false

    enum DevToolsTab: String, CaseIterable {
        case artifacts = "Build Artifacts"
        case packages = "Package Managers"
    }

    private var showsTabPicker: Bool {
        hasCompletedBuildArtifactScan && !isBuildArtifactScanRunning
    }

    var body: some View {
        FeaturePageShell(
            title: "Developer Tools",
            subtitle: "Clean build artifacts, caches, and stale Git branches.",
            scrolls: selectedTab == .artifacts && !showsTabPicker
        ) {
            VStack(spacing: 0) {
                if showsTabPicker {
                    Picker("", selection: $selectedTab) {
                        ForEach(DevToolsTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(12)

                    Divider()
                        .overlay(MacSweepTheme.divider)
                }

                switch selectedTab {
                case .artifacts:
                    BuildArtifactsView(
                        hasCompletedScan: $hasCompletedBuildArtifactScan,
                        isScanRunning: $isBuildArtifactScanRunning
                    )
                case .packages:
                    PackageManagersView()
                }
            }
        }
    }
}

/// View for cleaning up build artifacts (node_modules, DerivedData, etc.)
struct BuildArtifactsView: View {
    @EnvironmentObject var appState: AppState
    @Binding private var hasCompletedScan: Bool
    @Binding private var isScanRunning: Bool
    @State private var isScanning = false
    @State private var projects: [ProjectInfo] = []
    @State private var projectCleanupItems: [CleanupItem] = []
    @State private var systemArtifacts: [CleanupItem] = []
    @State private var gitArtifacts: [GitCleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var selectedGitItems: Set<UUID> = []
    @State private var errorMessage: String?
    @State private var gitToolStatus: GitToolStatus?
    @State private var showingConfirmation = false
    @State private var viewMode: ViewMode = .projects
    @State private var filterType: ProjectType? = nil

    enum ViewMode: String, CaseIterable {
        case projects = "By Project"
        case type = "By Type"
        case all = "All Items"
    }

    init(
        hasCompletedScan: Binding<Bool> = .constant(false),
        isScanRunning: Binding<Bool> = .constant(false)
    ) {
        self._hasCompletedScan = hasCompletedScan
        self._isScanRunning = isScanRunning
    }

    var body: some View {
        Group {
            if isScanning {
                ScanLandingView(
                    icon: "hammer",
                    title: "Find Developer Artifacts",
                    description: "Scan for node_modules, DerivedData, stale worktrees, and merged branches.",
                    ctaTitle: "Scan Developer Tools",
                    benefits: [
                        ScanBenefit("internaldrive", "Reclaims gigabytes of build junk", "Sweeps node_modules, DerivedData, and build caches that quietly pile up across every project on your Mac."),
                        ScanBenefit("arrow.triangle.branch", "Tidies stale Git clutter", "Spots merged branches and abandoned worktrees, while flagging projects in active development so nothing live gets touched."),
                    ],
                    illustration: "hammer",
                    isScanning: true,
                    action: { Task { await scan() } }
                )
            } else if !hasCompletedScan {
                ScanLandingView(
                    icon: "hammer",
                    title: "Find Developer Artifacts",
                    description: "Scan for node_modules, DerivedData, stale worktrees, and merged branches.",
                    ctaTitle: "Scan Developer Tools",
                    benefits: [
                        ScanBenefit("internaldrive", "Reclaims gigabytes of build junk", "Sweeps node_modules, DerivedData, and build caches that quietly pile up across every project on your Mac."),
                        ScanBenefit("arrow.triangle.branch", "Tidies stale Git clutter", "Spots merged branches and abandoned worktrees, while flagging projects in active development so nothing live gets touched."),
                    ],
                    illustration: "hammer",
                    action: { Task { await scan() } }
                )
            } else if projects.isEmpty && systemArtifacts.isEmpty && gitArtifacts.isEmpty {
                noArtifactsView
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                        .overlay(MacSweepTheme.divider)

                    contentView

                    Divider()
                        .overlay(MacSweepTheme.divider)
                    footer
                }
            }
        }
        .errorAlert("Cleanup Failed", message: $errorMessage)
    }

    private var noArtifactsView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(MacSweepTheme.accent)

            Text("No Developer Artifacts Found")
                .font(.headline)

            Text("No build artifacts, stale worktrees, or merged branches were found.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await scan() }
            } label: {
                Label("Scan Again", systemImage: "arrow.clockwise")
            }
            .glassButton()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 12) {
            HStack {
                // View mode picker
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                Button {
                    Task { await scan() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(isScanning)
            }

            // Project type filter
            if viewMode == .projects && !projects.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(label: "All", isSelected: filterType == nil) {
                            filterType = nil
                        }

                        ForEach(availableTypes, id: \.self) { type in
                            FilterChip(label: type.rawValue, isSelected: filterType == type) {
                                filterType = type
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            if let gitToolStatus {
                HStack(spacing: 8) {
                    Label(
                        gitToolStatus.canUseGitHubCLI ? "GitHub CLI connected" : (gitToolStatus.ghPath == nil ? "GitHub CLI unavailable" : "GitHub CLI installed"),
                        systemImage: gitToolStatus.canUseGitHubCLI ? "checkmark.circle.fill" : "terminal"
                    )
                    .font(.caption2)
                    .foregroundStyle(gitToolStatus.canUseGitHubCLI ? .green : .secondary)

                    Text(gitToolStatus.canUseGitHubCLI ? "PR state can help identify merged or closed stale branches." : "Local Git checks still protect branch and worktree cleanup.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
            }
        }
        .padding()
    }

    // MARK: - Content View

    @ViewBuilder
    private var contentView: some View {
        switch viewMode {
        case .projects:
            projectsView
        case .type:
            byTypeView
        case .all:
            allItemsView
        }
    }

    private var projectsView: some View {
        List(selection: $selectedItems) {
            // Projects section
            if !filteredProjects.isEmpty {
                Section("Projects (\(filteredProjects.count))") {
                    ForEach(filteredProjects) { project in
                        ProjectRow(
                            project: project,
                            isSelected: cleanupItemIDs(for: project).allSatisfy { selectedItems.contains($0) },
                            onToggle: {
                                toggleProject(project)
                            }
                        )
                    }
                }
            }

            // System artifacts section
            if !systemArtifacts.isEmpty {
                Section("System Artifacts") {
                    ForEach(systemArtifacts) { item in
                        ArtifactRow(item: item, isSelected: selectedItems.contains(item.id))
                            .tag(item.id)
                    }
                }
            }

            if !gitArtifacts.isEmpty {
                Section("Stale Git Worktrees & Branches") {
                    ForEach(gitArtifacts) { item in
                        GitArtifactRow(
                            item: item,
                            isSelected: selectedGitItems.contains(item.id),
                            onToggle: {
                                toggleGitItem(item)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var byTypeView: some View {
        List(selection: $selectedItems) {
            ForEach(ProjectType.allCases, id: \.self) { type in
                let typeProjects = projects.filter { $0.type == type }
                if !typeProjects.isEmpty {
                    Section {
                        ForEach(typeProjects) { project in
                            ProjectRow(
                                project: project,
                                isSelected: cleanupItemIDs(for: project).allSatisfy { selectedItems.contains($0) },
                                onToggle: { toggleProject(project) }
                            )
                        }
                    } header: {
                        HStack {
                            Image(systemName: type.icon)
                            Text(type.rawValue)
                            Spacer()
                            Text("\(typeProjects.count) projects • \(totalSizeForType(type))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var allItemsView: some View {
        List(selection: $selectedItems) {
            if !allCleanupItems.isEmpty {
                Section("Build Artifacts") {
                    ForEach(allCleanupItems) { item in
                        ArtifactRow(item: item, isSelected: selectedItems.contains(item.id))
                            .tag(item.id)
                    }
                }
            }

            if !gitArtifacts.isEmpty {
                Section("Stale Git Worktrees & Branches") {
                    ForEach(gitArtifacts) { item in
                        GitArtifactRow(
                            item: item,
                            isSelected: selectedGitItems.contains(item.id),
                            onToggle: {
                                toggleGitItem(item)
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(selectedCount) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if recentlyModifiedCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text("\(recentlyModifiedCount) active")
                                .font(.caption2)
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                    }
                }

                Text("Will free \(selectedSize)")
                    .font(.headline)
            }

            Spacer()

            // Quick actions
            Button("Select All") {
                selectedItems = Set(allCleanupItems.map(\.id))
                selectedGitItems = Set(gitArtifacts.map(\.id))
            }
            .glassButton()

            Button("Select Stale Only") {
                selectStaleOnly()
            }
            .glassButton()
            .help("Select only projects not modified in the last 48 hours")

            Button("Clean Selected") {
                showingConfirmation = true
            }
            .glassButton(prominent: true)
            .tint(.red)
            .disabled(selectedItems.isEmpty && selectedGitItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Clean \(selectedCount) items?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean Selected", role: .destructive) {
                Task {
                    await cleanSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if recentlyModifiedCount > 0 {
                Text("Warning: \(recentlyModifiedCount) selected project(s) were modified recently and may be in active development.\n\nThis will move build artifacts to Trash and remove selected stale Git worktrees or branches.")
            } else {
                Text("This will move build artifacts to Trash and remove selected stale Git worktrees or branches.")
            }
        }
    }

    // MARK: - Actions

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        isScanRunning = true
        projects = []
        projectCleanupItems = []
        systemArtifacts = []
        gitArtifacts = []
        selectedItems = []
        selectedGitItems = []

        defer {
            isScanning = false
            isScanRunning = false
            hasCompletedScan = true
        }

        // Scan for projects
        let scanner = ProjectScanner()
        projects = await scanner.discoverProjects(in: FileManager.default.homeDirectoryForCurrentUser)
        projectCleanupItems = await buildCleanupItems(for: projects)

        // Scan for system artifacts (DerivedData, etc.)
        let module = DevToolsModule()
        systemArtifacts = (try? await module.scan()) ?? []

        // Filter out duplicates
        let projectPaths = Set(projects.flatMap(\.artifactPaths).map(\.path))
        systemArtifacts = systemArtifacts.filter { !projectPaths.contains($0.path.path) }

        let gitScanner = GitArtifactScanner()
        gitToolStatus = await gitScanner.toolStatus()
        gitArtifacts = await gitScanner.discoverStaleArtifacts()
    }

    private func toggleProject(_ project: ProjectInfo) {
        let itemIDs = cleanupItemIDs(for: project)
        guard !itemIDs.isEmpty else { return }

        if itemIDs.allSatisfy({ selectedItems.contains($0) }) {
            selectedItems.subtract(itemIDs)
        } else {
            selectedItems.formUnion(itemIDs)
        }
    }

    private func toggleGitItem(_ item: GitCleanupItem) {
        if selectedGitItems.contains(item.id) {
            selectedGitItems.remove(item.id)
        } else {
            selectedGitItems.insert(item.id)
        }
    }

    private func selectStaleOnly() {
        // Select only projects that haven't been modified recently (not in last 48 hours)
        let staleProjectIds = Set(
            projects.filter { !$0.isModifiedRecently }.flatMap { project in
                allCleanupItems.filter { item in
                    project.artifactPaths.contains(item.path)
                }.map(\.id)
            }
        )

        // Also include system artifacts (DerivedData, etc.) that are safe
        let systemIds = Set(systemArtifacts.map(\.id))

        selectedItems = staleProjectIds.union(systemIds)
        selectedGitItems = Set(gitArtifacts.map(\.id))
    }

    private func selectCachesOnly() {
        // Select only cache-type artifacts (not source dependencies)
        let cacheNames = ["DerivedData", "__pycache__", ".gradle", "build", ".build", "target", "bin", "obj", ".next", ".nuxt", ".turbo", ".cache"]
        selectedItems = Set(
            allCleanupItems.filter { item in
                cacheNames.contains(where: { item.path.lastPathComponent.contains($0) || item.moduleName.contains($0) })
            }.map(\.id)
        )
    }

    private func cleanSelected() async {
        let itemsToClean = allCleanupItems.filter { selectedItems.contains($0.id) }
        let gitItemsToClean = gitArtifacts.filter { selectedGitItems.contains($0.id) }

        // Route through ScanEngine so the full safety pipeline (per-item
        // SafetyChecker + aggregate DeletionGuard cap) applies, not just the
        // module's own delete. A blocked delete throws and is caught here.
        var failures: [String] = []
        if !itemsToClean.isEmpty {
            let engine = ScanEngine()
            do {
                let result = try await engine.clean(items: itemsToClean, dryRun: false)
                if let summary = result.failureSummaryMessage {
                    failures.append(summary)
                }
            } catch {
                failures.append("Cleanup failed: \(error.localizedDescription)")
            }
        }

        if !gitItemsToClean.isEmpty {
            let result = await GitArtifactCleaner().clean(items: gitItemsToClean, dryRun: false)
            if let summary = result.errors.failureSummaryMessage {
                failures.append("Git artifacts: \(summary)")
            }
        }

        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")

        // Refresh
        await scan()
    }

    // MARK: - Computed

    private var filteredProjects: [ProjectInfo] {
        if let filterType = filterType {
            return projects.filter { $0.type == filterType }
        }
        return projects
    }

    private var availableTypes: [ProjectType] {
        let types = Set(projects.map(\.type))
        return ProjectType.allCases.filter { types.contains($0) }
    }

    private var allCleanupItems: [CleanupItem] {
        (projectCleanupItems + systemArtifacts).sorted { $0.size > $1.size }
    }

    private var selectedSize: String {
        let cleanupTotal = allCleanupItems
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        let gitTotal = gitArtifacts
            .filter { selectedGitItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        let total = cleanupTotal + gitTotal
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private var selectedCount: Int {
        selectedItems.count + selectedGitItems.count
    }

    private var recentlyModifiedCount: Int {
        // Count how many selected items belong to recently modified projects
        var count = 0
        for project in projects where project.isModifiedRecently {
            let hasSelectedArtifact = allCleanupItems.contains { item in
                project.artifactPaths.contains(item.path) && selectedItems.contains(item.id)
            }
            if hasSelectedArtifact {
                count += 1
            }
        }
        return count
    }

    private func totalSizeForType(_ type: ProjectType) -> String {
        let total = projects.filter { $0.type == type }.reduce(0) { $0 + $1.artifactSize }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func cleanupItemIDs(for project: ProjectInfo) -> Set<UUID> {
        Set(projectCleanupItems.filter { project.artifactPaths.contains($0.path) }.map(\.id))
    }

    private func buildCleanupItems(for projects: [ProjectInfo]) async -> [CleanupItem] {
        var items: [CleanupItem] = []
        for project in projects {
            for path in project.artifactPaths {
                let size = (try? await DiskAnalyzer.directorySize(at: path)) ?? 0
                let lastModified = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                items.append(CleanupItem(
                    id: UUID(),
                    path: path,
                    size: size,
                    type: .directory,
                    module: "dev-tools",
                    moduleName: "\(project.type.rawValue) - \(project.name)",
                    lastModified: lastModified
                ))
            }
        }
        return items
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: ProjectInfo
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var showingRegenCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Selection checkbox
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .onTapGesture { onToggle() }

                // Type icon
                Image(systemName: project.type.icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(colorFor(type: project.type))

                // Project info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.body)
                            .lineLimit(1)

                        // Recently modified warning
                        if project.isRecentlyModified {
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                Text("Active")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .help("Modified \(project.timeSinceModified ?? "recently") - this project may be in active development")
                        } else if project.isModifiedRecently {
                            HStack(spacing: 2) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                Text("Recent")
                                    .font(.caption2)
                            }
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.15), in: Capsule())
                            .help("Modified \(project.timeSinceModified ?? "recently")")
                        }
                    }

                    HStack(spacing: 8) {
                        Text(project.type.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorFor(type: project.type).opacity(0.2), in: Capsule())
                            .foregroundStyle(colorFor(type: project.type))

                        if let timeSince = project.timeSinceModified {
                            Text(timeSince)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        Text(project.path.path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer()

                // Artifacts
                VStack(alignment: .trailing, spacing: 2) {
                    Text(project.formattedSize)
                        .font(.headline)

                    Text("\(project.artifactPaths.count) artifacts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Info button for regeneration command
                Button {
                    showingRegenCommand.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showingRegenCommand) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Regenerate with:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(project.regenerateCommand)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(project.regenerateCommand, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .help("Copy to clipboard")
                        }
                    }
                    .padding()
                }

                // Reveal in Finder
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.path])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func colorFor(type: ProjectType) -> Color {
        switch type {
        case .nodejs: return .green
        case .swift: return .orange
        case .rust: return .red
        case .python: return .blue
        case .java: return .brown
        case .xcode: return .purple
        case .go: return .cyan
        case .ruby: return .red
        case .php: return .indigo
        case .dotnet: return .purple
        }
    }
}

// MARK: - Artifact Row

struct ArtifactRow: View {
    let item: CleanupItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            Image(systemName: "folder.fill")
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.moduleName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)

                    Text(item.path.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Text(item.formattedSize)
                .font(.headline)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Git Artifact Row

struct GitArtifactRow: View {
    let item: GitCleanupItem
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var showingCommand = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .onTapGesture { onToggle() }

            Image(systemName: item.kind.icon)
                .foregroundStyle(item.kind == .worktree ? .teal : .indigo)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)

                    Text(item.kind.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((item.kind == .worktree ? Color.teal : Color.indigo).opacity(0.16), in: Capsule())
                        .foregroundStyle(item.kind == .worktree ? .teal : .indigo)
                }

                HStack(spacing: 8) {
                    if let timeSince = item.timeSinceActivity {
                        Text(timeSince)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text((item.displayPath ?? item.repositoryPath).path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer()

            Text(item.formattedSize)
                .font(.headline)

            Button {
                showingCommand.toggle()
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .popover(isPresented: $showingCommand) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleanup command:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(item.commandPreview)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.commandPreview, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy to clipboard")
                    }
                }
                .padding()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.gray.opacity(0.2), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    DevToolsView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}

#endif
