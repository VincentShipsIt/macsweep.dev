import SwiftUI

/// DaisyDisk-style storage visualizer
struct SpaceLensView: View {
    @EnvironmentObject var appState: AppState
    @State private var isScanning = false
    @State private var rootNode: DiskNode?
    @State private var currentPath: [DiskNode] = []
    @State private var selectedNode: DiskNode?
    @State private var diskStats: DiskQuickStats?
    @State private var viewMode: ViewMode = .treemap
    @State private var nodeToTrash: DiskNode?
    @State private var showingTrashConfirmation = false
    @State private var errorMessage: String?

    enum ViewMode: String, CaseIterable {
        case treemap = "Treemap"
        case sunburst = "Sunburst"
        case list = "List"
    }

    private var currentNode: DiskNode? {
        currentPath.last ?? rootNode
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                errorBanner(errorMessage)
            }
            header
            Divider()

            if isScanning {
                scanningView
            } else if let node = currentNode {
                HSplitView {
                    visualizationPane(node: node)
                        .frame(minWidth: 400)

                    detailPane
                        .frame(minWidth: 250, maxWidth: 350)
                }
            } else {
                emptyState
            }
        }
    }

    // MARK: - Error Banner

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

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space Lens")
                        .font(.title)
                        .fontWeight(.bold)

                    if let stats = diskStats {
                        Text("\(stats.formattedUsed) used of \(stats.formattedTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // View mode picker
                Picker("View", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: iconFor(mode: mode))
                            .tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)

                Button {
                    Task {
                        await scanDisk()
                    }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .glassButton(prominent: true)
                .disabled(isScanning)
            }

            // Breadcrumb navigation
            if !currentPath.isEmpty {
                breadcrumbs
            }
        }
        .padding()
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button {
                currentPath.removeAll()
                selectedNode = nil
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.plain)

            if let root = rootNode {
                Text(root.name)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(currentPath.enumerated()), id: \.element.id) { index, node in
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Button {
                    // Navigate to this level
                    currentPath = Array(currentPath.prefix(index + 1))
                    selectedNode = nil
                } label: {
                    Text(node.name)
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == currentPath.count - 1 ? .primary : .secondary)
            }

            Spacer()

            Button("Back") {
                currentPath.removeLast()
                selectedNode = nil
            }
            .glassButton()
        }
    }

    // MARK: - Visualization Pane

    private func visualizationPane(node: DiskNode) -> some View {
        Group {
            switch viewMode {
            case .treemap:
                TreemapView(
                    node: node,
                    selectedNode: $selectedNode,
                    onDrillDown: drillDown
                )
            case .sunburst:
                SunburstView(
                    node: node,
                    selectedNode: $selectedNode,
                    onDrillDown: drillDown
                )
            case .list:
                listView(node: node)
            }
        }
    }

    private func listView(node: DiskNode) -> some View {
        List(selection: $selectedNode) {
            ForEach(node.children) { child in
                SpaceLensRow(node: child, parentSize: node.size)
                    .tag(child)
                    .onTapGesture(count: 2) {
                        if child.isDirectory {
                            drillDown(child)
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        VStack(spacing: 0) {
            if let node = selectedNode {
                nodeDetail(node)
            } else if let node = currentNode {
                folderSummary(node)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            "Move to Trash?",
            isPresented: $showingTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let node = nodeToTrash {
                    Task { await moveToTrash(node) }
                }
                nodeToTrash = nil
            }
            Button("Cancel", role: .cancel) {
                nodeToTrash = nil
            }
        } message: {
            if let node = nodeToTrash {
                Text("\"\(node.name)\" (\(node.formattedSize)) will be moved to the Trash. You can restore it from there until the Trash is emptied.")
            }
        }
    }

    private func nodeDetail(_ node: DiskNode) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Icon
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(colorFor(node: node))

                // Name
                Text(node.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                // Size
                Text(node.formattedSize)
                    .font(.title)
                    .fontWeight(.bold)

                // Path
                Text(node.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Divider()

                // Actions
                VStack(spacing: 12) {
                    if node.isDirectory {
                        Button {
                            drillDown(node)
                        } label: {
                            Label("Open", systemImage: "folder.badge.gearshape")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([node.url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton()

                    Button {
                        nodeToTrash = node
                        showingTrashConfirmation = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    .tint(.red)
                }
                .padding()

                Spacer()
            }
            .padding()
        }
    }

    private func folderSummary(_ node: DiskNode) -> some View {
        VStack(spacing: 16) {
            Text("Folder Summary")
                .font(.headline)
                .padding(.top)

            // Stats
            VStack(spacing: 8) {
                StatRow(label: "Items", value: "\(node.children.count)")
                StatRow(label: "Total Size", value: node.formattedSize)

                if let largest = node.children.first {
                    StatRow(label: "Largest", value: "\(largest.name) (\(largest.formattedSize))")
                }
            }
            .padding()

            Divider()

            // Legend
            VStack(alignment: .leading, spacing: 8) {
                Text("File Types")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LegendRow(color: .purple, label: "Video")
                LegendRow(color: .green, label: "Images")
                LegendRow(color: .orange, label: "Audio")
                LegendRow(color: .yellow, label: "Archives")
                LegendRow(color: .red, label: "Documents")
                LegendRow(color: .blue, label: "Folders")
                LegendRow(color: .gray, label: "Other")
            }
            .padding()

            Spacer()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.pie")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Visualize Disk Space")
                .font(.headline)

            Text("Scan to see what's taking up space on your disk")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Start Scan") {
                Task {
                    await scanDisk()
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

            Text("Analyzing disk...")
                .font(.headline)

            Text("This may take a moment for large directories")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func scanDisk() async {
        isScanning = true
        currentPath = []
        selectedNode = nil
        errorMessage = nil

        defer { isScanning = false }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        // Get disk stats
        diskStats = await DiskAnalyzer.quickStats(at: homeDir)

        // Build disk tree
        do {
            rootNode = try await DiskAnalyzer.buildDiskTree(at: homeDir, maxDepth: 2)

            // Calculate percentages
            if var node = rootNode, node.size > 0 {
                for i in node.children.indices {
                    node.children[i].percentage = Double(node.children[i].size) / Double(node.size)
                }
                rootNode = node
            }
        } catch {
            errorMessage = "Couldn't analyze disk: \(error.localizedDescription)"
        }
    }

    private func drillDown(_ node: DiskNode) {
        guard node.isDirectory else { return }

        Task {
            isScanning = true
            defer { isScanning = false }

            do {
                var detailedNode = try await DiskAnalyzer.buildDiskTree(at: node.url, maxDepth: 2)

                // Calculate percentages
                if detailedNode.size > 0 {
                    for i in detailedNode.children.indices {
                        detailedNode.children[i].percentage = Double(detailedNode.children[i].size) / Double(detailedNode.size)
                    }
                }

                currentPath.append(detailedNode)
                selectedNode = nil
            } catch {
                errorMessage = "Couldn't open folder: \(error.localizedDescription)"
            }
        }
    }

    private func moveToTrash(_ node: DiskNode) async {
        // Space Lens lets the user trash an ARBITRARY path they drilled into, so the
        // default-deny cleanup allowlist (ScanEngine.clean, which also silently
        // no-ops on an unregistered module id) is the wrong gate. Use the blocklist
        // gate instead: refuse system/credential/cloud roots and whole user folders,
        // allow arbitrary user files, then move to Trash (recoverable). Surface any
        // failure and do NOT drop the node from the map unless the trash succeeded.
        let validation = SafetyChecker().validateForTrash(node.url)
        guard validation.isSafe else {
            errorMessage = "Can't move \"\(node.name)\" to Trash: \(validation.reason ?? "protected path")"
            return
        }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            errorMessage = "Couldn't move \"\(node.name)\" to Trash: \(error.localizedDescription)"
            return
        }

        // Refresh current view
        if var current = currentPath.last {
            current.children.removeAll { $0.id == node.id }
            currentPath[currentPath.count - 1] = current
        } else if var root = rootNode {
            root.children.removeAll { $0.id == node.id }
            rootNode = root
        }

        selectedNode = nil
        errorMessage = nil
    }

    // MARK: - Helpers

    private func iconFor(mode: ViewMode) -> String {
        switch mode {
        case .treemap: return "square.grid.2x2"
        case .sunburst: return "chart.pie"
        case .list: return "list.bullet"
        }
    }

    private func colorFor(node: DiskNode) -> Color {
        switch node.color {
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "red": return .red
        case "blue": return .blue
        case "cyan": return .cyan
        default: return .gray
        }
    }
}

// MARK: - Treemap View

struct TreemapView: View {
    let node: DiskNode
    @Binding var selectedNode: DiskNode?
    let onDrillDown: (DiskNode) -> Void

    var body: some View {
        GeometryReader { geometry in
            let rects = calculateTreemap(
                items: node.children,
                bounds: CGRect(origin: .zero, size: geometry.size)
            )

            ZStack {
                ForEach(Array(zip(node.children, rects)), id: \.0.id) { child, rect in
                    TreemapCell(
                        node: child,
                        rect: rect,
                        isSelected: selectedNode?.id == child.id,
                        onTap: { selectedNode = child },
                        onDoubleTap: { if child.isDirectory { onDrillDown(child) } }
                    )
                }
            }
        }
        .padding()
    }

    private func calculateTreemap(items: [DiskNode], bounds: CGRect) -> [CGRect] {
        guard !items.isEmpty else { return [] }

        let totalSize = items.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return items.map { _ in .zero } }

        var rects: [CGRect] = []
        var remaining = bounds
        var remainingItems = items

        while !remainingItems.isEmpty {
            // Take items for this row
            let rowItems: [DiskNode]
            let isHorizontal = remaining.width >= remaining.height

            if remainingItems.count == 1 {
                rowItems = remainingItems
                remainingItems = []
            } else {
                // Take roughly half by size
                var rowSize: Int64 = 0
                let targetSize = remainingItems.reduce(0) { $0 + $1.size } / 2
                var splitIndex = 0

                for (index, item) in remainingItems.enumerated() {
                    rowSize += item.size
                    if rowSize >= targetSize {
                        splitIndex = max(1, index)
                        break
                    }
                }

                rowItems = Array(remainingItems.prefix(splitIndex + 1))
                remainingItems = Array(remainingItems.dropFirst(splitIndex + 1))
            }

            let rowTotal = rowItems.reduce(0) { $0 + $1.size }
            let remainingTotal = remainingItems.reduce(0) { $0 + $1.size }
            let rowRatio = Double(rowTotal) / Double(rowTotal + remainingTotal)

            // Calculate row bounds
            let rowBounds: CGRect
            if isHorizontal {
                let width = remaining.width * rowRatio
                rowBounds = CGRect(x: remaining.minX, y: remaining.minY, width: width, height: remaining.height)
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: remaining.width - width, height: remaining.height)
            } else {
                let height = remaining.height * rowRatio
                rowBounds = CGRect(x: remaining.minX, y: remaining.minY, width: remaining.width, height: height)
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: remaining.height - height)
            }

            // Layout items within row
            var offset: CGFloat = 0
            for item in rowItems {
                let itemRatio = Double(item.size) / Double(rowTotal)

                let rect: CGRect
                if isHorizontal {
                    let height = rowBounds.height * itemRatio
                    rect = CGRect(x: rowBounds.minX, y: rowBounds.minY + offset, width: rowBounds.width, height: height)
                    offset += height
                } else {
                    let width = rowBounds.width * itemRatio
                    rect = CGRect(x: rowBounds.minX + offset, y: rowBounds.minY, width: width, height: rowBounds.height)
                    offset += width
                }

                rects.append(rect)
            }
        }

        return rects
    }
}

struct TreemapCell: View {
    let node: DiskNode
    let rect: CGRect
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    private var color: Color {
        switch node.color {
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "red": return .red
        case "blue": return .blue
        case "cyan": return .cyan
        default: return .gray
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? .white : .clear, lineWidth: 3)
            )
            .overlay(
                VStack(spacing: 2) {
                    if rect.width > 60 && rect.height > 40 {
                        Text(node.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(2)

                        Text(node.formattedSize)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.white)
                .padding(4)
            )
            .frame(width: rect.width - 2, height: rect.height - 2)
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture { onTap() }
            .onTapGesture(count: 2) { onDoubleTap() }
    }
}

// MARK: - Sunburst View

struct SunburstView: View {
    let node: DiskNode
    @Binding var selectedNode: DiskNode?
    let onDrillDown: (DiskNode) -> Void

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = min(geometry.size.width, geometry.size.height) / 2 - 20

            ZStack {
                // Center circle
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: maxRadius * 0.4, height: maxRadius * 0.4)
                    .overlay(
                        VStack {
                            Text(node.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text(node.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    )

                // Arcs for children
                ForEach(Array(arcs(radius: maxRadius).enumerated()), id: \.element.node.id) { index, arc in
                    SunburstArc(
                        arc: arc,
                        center: center,
                        isSelected: selectedNode?.id == arc.node.id,
                        onTap: { selectedNode = arc.node },
                        onDoubleTap: { if arc.node.isDirectory { onDrillDown(arc.node) } }
                    )
                }
            }
        }
        .padding()
    }

    private func arcs(radius: CGFloat) -> [SunburstArcData] {
        var result: [SunburstArcData] = []
        var startAngle: Double = -90

        let totalSize = node.children.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return [] }

        for child in node.children {
            let sweep = 360 * (Double(child.size) / Double(totalSize))
            result.append(SunburstArcData(
                node: child,
                startAngle: startAngle,
                endAngle: startAngle + sweep,
                innerRadius: radius * 0.25,
                outerRadius: radius * 0.9
            ))
            startAngle += sweep
        }

        return result
    }
}

struct SunburstArcData {
    let node: DiskNode
    let startAngle: Double
    let endAngle: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat
}

struct SunburstArc: View {
    let arc: SunburstArcData
    let center: CGPoint
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void

    private var color: Color {
        switch arc.node.color {
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "red": return .red
        case "blue": return .blue
        case "cyan": return .cyan
        default: return .gray
        }
    }

    var body: some View {
        ArcShape(
            startAngle: .degrees(arc.startAngle),
            endAngle: .degrees(arc.endAngle),
            innerRadius: arc.innerRadius,
            outerRadius: isSelected ? arc.outerRadius + 10 : arc.outerRadius
        )
        .fill(color.opacity(isSelected ? 1 : 0.8))
        .overlay(
            ArcShape(
                startAngle: .degrees(arc.startAngle),
                endAngle: .degrees(arc.endAngle),
                innerRadius: arc.innerRadius,
                outerRadius: isSelected ? arc.outerRadius + 10 : arc.outerRadius
            )
            .stroke(.white.opacity(0.3), lineWidth: 1)
        )
        .offset(x: center.x, y: center.y)
        .onTapGesture { onTap() }
        .onTapGesture(count: 2) { onDoubleTap() }
    }
}

struct ArcShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let startOuter = pointOnCircle(angle: startAngle, radius: outerRadius)
        let endOuter = pointOnCircle(angle: endAngle, radius: outerRadius)
        let startInner = pointOnCircle(angle: startAngle, radius: innerRadius)
        let endInner = pointOnCircle(angle: endAngle, radius: innerRadius)

        path.move(to: startInner)
        path.addLine(to: startOuter)
        path.addArc(center: .zero, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addLine(to: endInner)
        path.addArc(center: .zero, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()

        return path
    }

    private func pointOnCircle(angle: Angle, radius: CGFloat) -> CGPoint {
        CGPoint(
            x: CGFloat(Darwin.cos(angle.radians)) * radius,
            y: CGFloat(Darwin.sin(angle.radians)) * radius
        )
    }
}

// MARK: - Supporting Views

struct SpaceLensRow: View {
    let node: DiskNode
    let parentSize: Int64

    private var percentage: Double {
        guard parentSize > 0 else { return 0 }
        return Double(node.size) / Double(parentSize) * 100
    }

    private var color: Color {
        switch node.color {
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        case "yellow": return .yellow
        case "red": return .red
        case "blue": return .blue
        case "cyan": return .cyan
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)

                // Size bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.gray.opacity(0.2))

                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: geo.size.width * (percentage / 100))
                    }
                }
                .frame(height: 4)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(node.formattedSize)
                    .font(.caption)

                Text(String(format: "%.1f%%", percentage))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct LegendRow: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)

            Text(label)
                .font(.caption)
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    SpaceLensView()
        .environmentObject(AppState())
        .frame(width: 900, height: 600)
}

#endif
