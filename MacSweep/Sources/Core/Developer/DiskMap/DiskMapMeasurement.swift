import Darwin
import Foundation

/// A bounded streaming walk. Classification never grants cleanup authority.
struct DiskMapMeasurement {
    struct Result: Sendable {
        var node: DiskMapNode
        var issues: [String]
        var hardLinks: Set<String>
    }
    var limits = DiskMapLimits()
    var checker = SafetyChecker()
    var beforeRead: @Sendable (URL) throws -> Void = { _ in }

    private static let generatedNames: Set<String> = [
        "node_modules", ".build", "dist", "target", "build", "DerivedData", "Pods", ".venv", "venv", ".next", ".nuxt"
    ]
    private struct Context {
        var root: DiskMapRoot
        var excluding: [URL]
        var depth = 0
        var generated = false
        var protection: String?
    }
    private struct Walk {
        var inspected = 0
        var visible = 0
        var hardLinks: Set<String>
        var issues: [String] = []
        let deadline: TimeInterval
        var stopped = false
        var protectedRoot = false

        mutating func issue(_ text: String) {
            if issues.count < 20 && !issues.contains(text) { issues.append(text) }
        }
    }

    func measure(_ root: DiskMapRoot, excluding: [URL] = [], hardLinks: Set<String> = []) throws -> Result {
        var walk = Walk(hardLinks: hardLinks, deadline: ProcessInfo.processInfo.systemUptime + max(0, limits.seconds))
        if case .protected = checker.validateForScan(root.url, moduleID: "dev-tools") { walk.protectedRoot = true }
        var node = try inspect(root.url, context: Context(root: root, excluding: excluding), walk: &walk)
        if root.kind == .repository { node = partitionRepository(node) }
        return Result(node: node, issues: walk.issues, hardLinks: walk.hardLinks.subtracting(hardLinks))
    }

    private func inspect(_ url: URL, context: Context, walk: inout Walk) throws -> DiskMapNode {
        try Task.checkCancellation()
        var node = DiskMapNode(
            id: url.path, url: url, name: url.lastPathComponent,
            kind: context.root.kind, owner: context.root.owner)
        if context.excluding.contains(where: { DiskMapRoots.contains($0, url) }) { return node }
        guard withinBudget(context.depth, walk: &walk) else {
            node.coverage = .partial
            return node
        }
        guard let metadata = metadata(url, node: &node, walk: &walk),
            permitsRead(url, node: &node, context: context, walk: walk)
        else { return node }
        if metadata.st_mode & S_IFMT == S_IFREG {
            return measureFile(metadata, node: node, generated: context.generated, walk: &walk)
        }
        do {
            try enumerate(url, node: &node, context: context, walk: &walk)
        } catch is CancellationError { throw CancellationError() } catch {
            node.coverage = node.logicalBytes == 0 ? .unknown : .partial
            walk.issue("A directory was unreadable; displayed bytes are incomplete.")
            ScanDiagnostics.current?.record(error, at: url)
        }
        appendRemainder(to: &node)
        node.children.sort { $0.allocatedBytes > $1.allocatedBytes }
        return node
    }

    private func withinBudget(_ depth: Int, walk: inout Walk) -> Bool {
        guard !walk.stopped, walk.inspected < max(0, limits.maximumEntries),
            ProcessInfo.processInfo.systemUptime < walk.deadline, depth <= max(0, limits.maximumDepth)
        else {
            walk.stopped = true
            walk.issue("A measurement reached its entry, depth or time budget; displayed bytes are a lower bound.")
            return false
        }
        walk.inspected += 1
        return true
    }

    private func metadata(_ url: URL, node: inout DiskMapNode, walk: inout Walk) -> stat? {
        switch checker.userRules.decision(for: url.path) {
        case .none: break
        default:
            node.protectedReason = "Protected, ignored or unavailable user rules; contents were not traversed."
            node.coverage = .unknown
            return nil
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            walk.issue("Some paths could not be inspected; displayed bytes are incomplete.")
            node.coverage = .unknown
            return nil
        }
        node.modified = Date(timeIntervalSince1970: TimeInterval(metadata.st_mtimespec.tv_sec))
        let type = metadata.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else {
            node.coverage = .unknown
            node.protectedReason =
                type == S_IFLNK ? "Symbolic link; target was not followed." : "Special file; not traversed."
            return nil
        }
        return metadata
    }

    private func permitsRead(_ url: URL, node: inout DiskMapNode, context: Context, walk: Walk) -> Bool {
        let validation = checker.validateForScan(url, moduleID: "dev-tools")
        switch validation {
        case .sensitive, .symlink:
            node.coverage = .unknown
            node.protectedReason = validation.reason
            return false
        case .protected:
            node.protectedReason = validation.reason
            if context.root.kind == .ordinary && context.depth > 0 && !walk.protectedRoot {
                node.coverage = .unknown
                return false
            }
        default: node.protectedReason = context.protection
        }
        return true
    }

    private func measureFile(_ metadata: stat, node: DiskMapNode, generated: Bool, walk: inout Walk) -> DiskMapNode {
        var node = node
        if metadata.st_nlink > 1 {
            let identity = "\(metadata.st_dev):\(metadata.st_ino)"
            guard walk.hardLinks.insert(identity).inserted else { return node }
        }
        node.logicalBytes = max(0, metadata.st_size)
        node.allocatedBytes = max(0, Int64(metadata.st_blocks) * 512)
        if generated {
            node.generatedLogical = node.logicalBytes
            node.generatedAllocated = node.allocatedBytes
        }
        return node
    }

    private func enumerate(_ url: URL, node: inout DiskMapNode, context: Context, walk: inout Walk) throws {
        try beforeRead(url)
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(directory) }
        while !walk.stopped {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var childContext = context
            childContext.depth += 1
            childContext.generated =
                context.generated || (context.root.kind == .repository && Self.generatedNames.contains(name))
            childContext.protection = node.protectedReason
            let child = try inspect(url.appending(path: name), context: childContext, walk: &walk)
            node.logicalBytes += child.logicalBytes
            node.allocatedBytes += child.allocatedBytes
            node.generatedLogical += child.generatedLogical
            node.generatedAllocated += child.generatedAllocated
            if child.coverage != .complete { node.coverage = .partial }
            if context.depth < limits.visibleDepth && walk.visible < limits.maximumVisibleNodes {
                walk.visible += 1
                node.children.append(child)
            }
        }
        if walk.stopped { node.coverage = .partial }
    }

    private func appendRemainder(to node: inout DiskMapNode) {
        guard !node.children.isEmpty else { return }
        let logical = node.logicalBytes - node.children.reduce(0) { $0 + $1.logicalBytes }
        let allocated = node.allocatedBytes - node.children.reduce(0) { $0 + $1.allocatedBytes }
        guard logical > 0 || allocated > 0 else { return }
        node.children.append(
            DiskMapNode(
                id: node.id + "#other", url: node.url, name: "Other measured contents", kind: node.kind,
                owner: node.owner, logicalBytes: logical, allocatedBytes: allocated,
                generatedLogical: node.generatedLogical - node.children.reduce(0) { $0 + $1.generatedLogical },
                generatedAllocated: node.generatedAllocated - node.children.reduce(0) { $0 + $1.generatedAllocated },
                coverage: node.coverage, protectedReason: node.protectedReason))
    }

    private func partitionRepository(_ node: DiskMapNode) -> DiskMapNode {
        var repository = node
        repository.children = [partition(node, generated: false), partition(node, generated: true)].compactMap { $0 }
        for index in repository.children.indices {
            repository.children[index].name =
                repository.children[index].kind == .generated
                ? "Generated artifacts" : "Source & repository metadata"
        }
        return repository
    }

    private func partition(_ original: DiskMapNode, generated: Bool) -> DiskMapNode? {
        var node = original
        node.id += generated ? "#generated" : "#source"
        node.logicalBytes = generated ? original.generatedLogical : original.logicalBytes - original.generatedLogical
        node.allocatedBytes =
            generated ? original.generatedAllocated : original.allocatedBytes - original.generatedAllocated
        guard node.logicalBytes > 0 || node.allocatedBytes > 0 || original.coverage != .complete else { return nil }
        node.kind = generated ? .generated : .source
        node.owner = generated ? .developerTools : nil
        node.children = original.children.compactMap { partition($0, generated: generated) }
        return node
    }
}
