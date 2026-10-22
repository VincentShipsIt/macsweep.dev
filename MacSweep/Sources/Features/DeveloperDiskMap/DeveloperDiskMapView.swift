import SwiftUI

struct DeveloperDiskMapView: View {
    @State private var report: DiskMapReport
    @State private var scanning = false
    @State private var task: Task<Void, Never>?
    @State private var trail: [String] = []
    @State private var selected: String?
    @State private var didStart: Bool
    private let service = DeveloperDiskMapService()
    private let onOpenOwner: ((DiskMapOwner) -> Void)?

    init(onOpenOwner: ((DiskMapOwner) -> Void)? = nil, snapshotReport: DiskMapReport? = nil) {
        self.onOpenOwner = onOpenOwner
        _report = State(initialValue: snapshotReport ?? DiskMapReport())
        _didStart = State(initialValue: snapshotReport != nil)
    }

    private var root: DiskMapNode { report.grouped }
    private var focus: DiskMapNode { trail.last.flatMap { root.find($0) } ?? root }
    private var detail: DiskMapNode? { selected.flatMap { root.find($0) } }

    var body: some View {
        FeaturePageShell(
            title: "Developer Disk Map", subtitle: "Understand disk usage before opening the owning cleanup tool."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                controls
                Text(
                    (report.cached ? "Recent measurements · " : "")
                        + (report.fullHome ? "Home + developer roots" : "Known developer roots")
                        + " · \(root.sizeLabel)"
                )
                .font(.headline)
                Text(
                    "\(root.logicalLabel). Allocated bytes are estimates; "
                        + "exclusive APFS recovery is unknown. VM data persists; swap has no action."
                )
                .font(.caption).foregroundStyle(.secondary)
                if !report.issues.isEmpty {
                    DisclosureGroup("\(report.issues.count) coverage notes") {
                        ForEach(report.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                }
                if report.roots.isEmpty {
                    ContentUnavailableView(
                        scanning ? "Measuring developer roots…" : "No measurements yet", systemImage: "square.grid.3x3",
                        description: Text("Known roots are checked first. A broader home scan is optional."))
                } else {
                    navigation
                    HSplitView {
                        DiskMapTreemap(node: focus, onSelect: { selected = $0.id }, onOpen: open)
                            .frame(minWidth: 360, minHeight: 240)
                        VStack(alignment: .leading, spacing: 12) {
                            if let detail { details(detail) }
                            List(focus.children) { node in
                                HStack {
                                    Button {
                                        selected = node.id
                                    } label: {
                                        HStack {
                                            Image(systemName: node.protectedReason == nil ? "folder" : "lock.shield")
                                            VStack(alignment: .leading) {
                                                Text(node.name).lineLimit(1)
                                                Text(node.sizeLabel).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }.buttonStyle(.plain)
                                    Spacer()
                                    if !node.children.isEmpty {
                                        Button {
                                            open(node)
                                        } label: {
                                            Image(systemName: "chevron.right")
                                        }
                                        .buttonStyle(.plain).help("Drill into \(node.name)")
                                    }
                                }
                            }.listStyle(.inset)
                        }.frame(minWidth: 270, idealWidth: 330)
                    }
                }
                Text(
                    "Measured \(report.measuredAt.formatted(date: .abbreviated, time: .shortened)) · "
                        + (scanning
                            ? "Incremental scan in progress"
                            : report.finished ? "Selected scope finished" : "Partial scope")
                        + " · No deletion from this map"
                )
                .font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
        .task { if !didStart { start(fullHome: false, refresh: false) } }
        .onDisappear { task?.cancel() }
    }

    private var controls: some View {
        HStack {
            Button(report.finished ? "Use Recent / Scan" : "Scan / Resume") {
                start(fullHome: report.fullHome, refresh: false)
            }
            .disabled(scanning)
            Button("Refresh") { start(fullHome: report.fullHome, refresh: true) }.disabled(scanning)
            Button("Measure Home…") { start(fullHome: true, refresh: false) }.disabled(scanning)
                .help("Explicitly measure other home files after developer roots. Protected paths remain excluded.")
            if scanning {
                ProgressView().controlSize(.small)
                Button("Cancel") { task?.cancel() }
            }
            Spacer()
        }.buttonStyle(.bordered).fixedSize(horizontal: false, vertical: true)
    }

    private var navigation: some View {
        HStack {
            Button("All Groups") {
                trail = []
                selected = nil
            }.disabled(trail.isEmpty)
            Button("Back") {
                if !trail.isEmpty { trail.removeLast() }
                selected = nil
            }.disabled(trail.isEmpty)
            Text(focus.name).font(.headline)
        }.buttonStyle(.bordered)
    }

    @ViewBuilder private func details(_ node: DiskMapNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(node.name).font(.headline)
            if let path = node.url { Text(path.path).font(.caption.monospaced()).textSelection(.enabled) }
            Text(node.sizeLabel).font(.callout)
            Text("\(node.logicalLabel) · \(node.coverage.rawValue) coverage").font(.caption)
            if let modified = node.modified { Text("Modified \(modified.formatted())").font(.caption) }
            if let reason = node.protectedReason { Text(reason).font(.caption).foregroundStyle(.orange) }
            HStack {
                if let path = node.url {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                }
                if let owner = node.owner, node.canOpenOwner, let onOpenOwner {
                    Button("Inspect in \(owner.title)") { onOpenOwner(owner) }
                }
            }.buttonStyle(.bordered)
            if !node.children.isEmpty { Button("Drill Down") { open(node) }.buttonStyle(.bordered) }
        }.padding(8)
    }

    private func open(_ node: DiskMapNode) {
        guard !node.children.isEmpty else {
            selected = node.id
            return
        }
        trail.append(node.id)
        selected = nil
    }

    @MainActor private func start(fullHome: Bool, refresh: Bool) {
        guard !scanning else { return }
        didStart = true
        scanning = true
        trail = []
        selected = nil
        task = Task {
            report = await service.scan(fullHome: fullHome, refresh: refresh) { update in
                await MainActor.run { report = update }
            }
            scanning = false
        }
    }
}

private struct DiskMapTreemap: View {
    let node: DiskMapNode
    let onSelect: (DiskMapNode) -> Void
    let onOpen: (DiskMapNode) -> Void
    private let layoutRoot: DiskNode

    init(node: DiskMapNode, onSelect: @escaping (DiskMapNode) -> Void, onOpen: @escaping (DiskMapNode) -> Void) {
        self.node = node
        self.onSelect = onSelect
        self.onOpen = onOpen
        layoutRoot = node.diskNode(maxDepth: 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let segments = DiskVisualizationLayout.treemap(
                root: node.diskNode(), bounds: CGRect(origin: .zero, size: geometry.size), maxDepth: 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                ForEach(segments) { segment in
                    if let item = node.find(segment.node.url.path) {
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.headline).lineLimit(2)
                                Text(item.sizeLabel).font(.caption).lineLimit(2)
                                if item.protectedReason != nil { Image(systemName: "lock.shield") }
                                Spacer(minLength: 0)
                            }.padding(8).frame(
                                width: segment.rect.width, height: segment.rect.height, alignment: .topLeading
                            )
                            .background(color(item.kind).opacity(0.28), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle()).clipped()
                        }.buttonStyle(.plain)
                            .position(x: segment.rect.midX, y: segment.rect.midY)
                            .help(
                                "\(item.url?.path ?? item.name)\n\(item.sizeLabel)\n"
                                    + "\(item.logicalLabel)\n"
                                    + (item.modified?.formatted() ?? "Date unavailable")
                            )
                            .contextMenu { if !item.children.isEmpty { Button("Drill Down") { onOpen(item) } } }
                            .accessibilityLabel("\(item.name), \(item.sizeLabel)")
                    }
                }
                if segments.isEmpty { Text("Size unknown or zero. Inspect the list for retained paths.").padding() }
            }
        }
    }

    private func color(_ kind: DiskMapKind) -> Color {
        switch kind {
        case .repository, .source: return .blue
        case .generated: return .orange
        case .toolchain: return .purple
        case .cache: return .green
        case .simulator: return .cyan
        case .vmData: return .pink
        case .swap, .ordinary: return .gray
        }
    }
}
