import SwiftUI

/// View for cleaning up developer artifacts
struct DevToolsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: DevToolsTab = .artifacts

    enum DevToolsTab: String, CaseIterable {
        case artifacts = "Build Artifacts"
        case packages = "Package Managers"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(DevToolsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Tab content
            switch selectedTab {
            case .artifacts:
                BuildArtifactsView()
            case .packages:
                PackageManagersView()
            }
        }
    }
}

/// View for cleaning up build artifacts (node_modules, DerivedData, etc.)
struct BuildArtifactsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var projects: [ProjectInfo] = []
    @State private var systemArtifacts: [CleanupItem] = []
    @State private var selectedItems: Set<UUID> = []
    @State private var showingConfirmation = false
    @State private var viewMode: ViewMode = .projects
    @State private var filterType: ProjectType? = nil

    enum ViewMode: String, CaseIterable {
        case projects = "By Project"
        case type = "By Type"
        case all = "All Items"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isScanning {
                scanningView
            } else if projects.isEmpty && systemArtifacts.isEmpty {
                emptyState
            } else {
                contentView
            }

            if (!projects.isEmpty || !systemArtifacts.isEmpty) && !isScanning {
                Divider()
                footer
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer Tools")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Clean build artifacts and dependencies")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // View mode picker
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)

                Button {
                    Task {
                        await scan()
                    }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .glassButton(prominent: true)
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
                            isSelected: project.artifactPaths.allSatisfy { path in
                                selectedItems.contains(where: { id in
                                    projects.first { $0.artifactPaths.contains(path) }?.id == project.id
                                })
                            },
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
        }
        .listStyle(.inset)
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
                                isSelected: false,
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
    }

    private var allItemsView: some View {
        List(selection: $selectedItems) {
            ForEach(allCleanupItems) { item in
                ArtifactRow(item: item, isSelected: selectedItems.contains(item.id))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Find Developer Artifacts")
                .font(.headline)

            Text("Scan to find node_modules, DerivedData, and other build artifacts")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Start Scan") {
                Task {
                    await scan()
                }
            }
            .glassButton(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)

            Text("Scanning for developer artifacts...")
                .font(.headline)

            Text("This may take a moment")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(selectedItems.count) selected")
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
            .disabled(selectedItems.isEmpty)
        }
        .padding()
        .confirmationDialog(
            "Clean \(selectedItems.count) items?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    await cleanSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if recentlyModifiedCount > 0 {
                Text("Warning: \(recentlyModifiedCount) selected project(s) were modified recently and may be in active development.\n\nThis will move \(selectedSize) of developer artifacts to Trash.")
            } else {
                Text("This will move \(selectedSize) of developer artifacts to Trash.")
            }
        }
    }

    // MARK: - Actions

    private func scan() async {
        isScanning = true
        projects = []
        systemArtifacts = []
        selectedItems = []

        defer { isScanning = false }

        // Scan for projects
        let scanner = ProjectScanner()
        projects = await scanner.discoverProjects(in: FileManager.default.homeDirectoryForCurrentUser)

        // Scan for system artifacts (DerivedData, etc.)
        let module = DevToolsModule()
        systemArtifacts = (try? await module.scan()) ?? []

        // Filter out duplicates
        let projectPaths = Set(projects.flatMap(\.artifactPaths).map(\.path))
        systemArtifacts = systemArtifacts.filter { !projectPaths.contains($0.path.path) }
    }

    private func toggleProject(_ project: ProjectInfo) {
        // Create cleanup items for project artifacts
        for path in project.artifactPaths {
            let item = allCleanupItems.first { $0.path == path }
            if let item = item {
                if selectedItems.contains(item.id) {
                    selectedItems.remove(item.id)
                } else {
                    selectedItems.insert(item.id)
                }
            }
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
        let module = DevToolsModule()

        _ = try? await module.clean(items: itemsToClean, dryRun: false)

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
        var items: [CleanupItem] = []

        // Convert projects to cleanup items
        for project in projects {
            for path in project.artifactPaths {
                let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int64) ?? 0
                items.append(CleanupItem(
                    id: UUID(),
                    path: path,
                    size: size,
                    type: .directory,
                    module: "dev-tools",
                    moduleName: "\(project.type.rawValue) - \(project.name)"
                ))
            }
        }

        // Add system artifacts
        items.append(contentsOf: systemArtifacts)

        return items.sorted { $0.size > $1.size }
    }

    private var selectedSize: String {
        let total = allCleanupItems
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
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
