import SwiftUI

struct AIAnalysisView: View {
    @StateObject private var service = AIAnalysisService()
    @State private var apiKeyInput = ""
    @State private var hasApiKey = false
    @State private var hasLocalAIProvider = false
    @State private var showKeyField = false
    @State private var keySaveError = false

    private var selectedFindings: [CacheFinding] {
        service.findings.filter { $0.isSelected }
    }

    private var totalSelectedSize: String {
        // Best effort: sum sizes where unit is clear
        let count = selectedFindings.count
        return "\(count) item\(count == 1 ? "" : "s") selected"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            if service.findings.isEmpty && !service.isScanning {
                emptyState
            } else {
                resultsList
            }

            Divider()

            // Bottom action bar
            bottomBar
        }
        .background(Color.clear)
        .onAppear {
            refreshProviderState()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 2) {
                Text("AI Analysis")
                    .font(.headline)
                Text("Claude/Codex-powered cache scanner")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // API key status
            Button {
                showKeyField.toggle()
            } label: {
                Label(providerStatusLabel, systemImage: hasLocalAIProvider ? "terminal" : "key")
                    .font(.caption)
                    .foregroundStyle(hasLocalAIProvider || hasApiKey ? .green : .orange)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showKeyField) {
                apiKeyPopover
            }

            Button {
                Task { await service.scan() }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .glassButton(prominent: true)
            .tint(.purple)
            .disabled(service.isScanning)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(MacSweepTheme.panelStrong)
    }

    // MARK: - API Key Popover

    private var apiKeyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anthropic API Key Fallback")
                .font(.headline)

            Text("MacSweep uses signed-in Claude or Codex CLIs first. A key is only needed as a fallback when local CLIs are unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280)

            Text("If the fallback API is used, item details — names, paths, sizes, and metadata — are sent to Anthropic's API (api.anthropic.com) for evaluation. File contents are never uploaded.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-...", text: $apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            if keySaveError {
                Text("Failed to save key. Check Keychain access.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if hasApiKey {
                    Button("Delete Key", role: .destructive) {
                        AIKeychainService.shared.deleteKey()
                        refreshProviderState()
                        apiKeyInput = ""
                        showKeyField = false
                    }
                    .glassButton()
                }
                Spacer()
                Button("Save") {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if AIKeychainService.shared.saveKey(trimmed) {
                        refreshProviderState()
                        apiKeyInput = ""
                        showKeyField = false
                        keySaveError = false
                    } else {
                        keySaveError = true
                    }
                }
                .glassButton(prominent: true)
                .tint(.purple)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(.purple.opacity(0.6))

            VStack(spacing: 8) {
                Text("AI-Powered Cache Analysis")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("Click Scan to find cache directories.\nPhase 1 is instant. Phase 2 uses Claude or Codex CLI for deeper analysis.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !hasLocalAIProvider && !hasApiKey {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                    Text("Install or sign in to Claude/Codex CLI, or add an API key fallback")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Progress

    private var progressBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.7)
            Text(service.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.12))
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                if service.isScanning {
                    progressBanner
                        .padding(.bottom, 4)
                }

                ForEach(CacheCategory.allCases) { category in
                    categorySection(for: category)
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// One category's section. Computing the global findings indices up front and
    /// binding directly to `$service.findings[globalIdx]` keeps each row a stable,
    /// independently-typed expression — the previous nested `filter` + `firstIndex`
    /// closure tree blew past the SwiftUI type-checker's time budget.
    @ViewBuilder
    private func categorySection(for category: CacheCategory) -> some View {
        let indices = service.findings.indices.filter { service.findings[$0].category == category }
        if !indices.isEmpty {
            Section {
                ForEach(Array(indices.enumerated()), id: \.element) { offset, globalIdx in
                    CacheFindingRow(finding: $service.findings[globalIdx])
                    if offset < indices.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            } header: {
                CategoryHeader(category: category, count: indices.count)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            // Select All / None
            Button(action: toggleSelectAll) {
                let allSelected = service.findings.allSatisfy { $0.isSelected }
                Text(allSelected ? "Deselect All" : "Select All")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            Text(totalSelectedSize)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if !service.findings.isEmpty {
                Button {
                    cleanSelected()
                } label: {
                    Label("Clean Selected", systemImage: "trash")
                }
                .glassButton(prominent: true)
                .tint(.red)
                .disabled(selectedFindings.isEmpty || service.isScanning)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(MacSweepTheme.panelStrong)
    }

    // MARK: - Actions

    private func toggleSelectAll() {
        let allSelected = service.findings.allSatisfy { $0.isSelected }
        for i in service.findings.indices {
            service.findings[i].isSelected = !allSelected
        }
    }

    private func cleanSelected() {
        let pathsToDelete = selectedFindings.map { $0.path }
        var deletedPaths: [String] = []
        var failedPaths: [String] = []
        var blockedPaths: [String] = []

        let safety = SafetyChecker()

        for path in pathsToDelete {
            let url = URL(fileURLWithPath: path)

            // AI suggestions are advisory — they MUST pass the same safety gate as
            // every other cleanup path before anything is touched. Pass the
            // `ai-analysis` module id so the dedicated allow-zone (the developer +
            // AI-tool cache roots CacheAnalyzer surfaces, which live outside
            // ~/Library/Caches) is reachable; without it those findings fail closed
            // and the feature's own results can't be cleaned.
            guard safety.validateForCleanup(url, moduleID: "ai-analysis").isSafe else {
                blockedPaths.append(path)
                continue
            }

            do {
                // Recoverable: AI false positives are possible, so move to Trash
                // rather than deleting outright.
                try CleanupFileRemover.recoverable(url)
                deletedPaths.append(path)
            } catch {
                failedPaths.append(path)
            }
        }

        // Remove deleted items from findings
        service.findings.removeAll { deletedPaths.contains($0.path) }

        var messages: [String] = []
        if !blockedPaths.isEmpty {
            messages.append("\(blockedPaths.count) item(s) blocked by safety checks")
        }
        if !failedPaths.isEmpty {
            messages.append("\(failedPaths.count) item(s) could not be moved to Trash (check permissions)")
        }
        if !messages.isEmpty {
            service.error = messages.joined(separator: "; ")
        }
    }

    private var providerStatusLabel: String {
        if hasLocalAIProvider { return "Local CLI ✓" }
        if hasApiKey { return "API Key ✓" }
        return "Add Fallback"
    }

    private func refreshProviderState() {
        hasApiKey = AIKeychainService.shared.loadKey() != nil
        hasLocalAIProvider = Self.executablePath(for: "claude") != nil || Self.executablePath(for: "codex") != nil
    }

    private static func executablePath(for command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Category Header

struct CategoryHeader: View {
    let category: CacheCategory
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: category.icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(category.rawValue)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("(\(count))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(MacSweepTheme.backgroundMid.opacity(0.96))
    }
}

// MARK: - Finding Row

/// Row for an AI-cache finding. Named distinctly from MalwareScanner's `FindingRow`
/// (a sibling top-level type in the same module) to avoid an invalid redeclaration.
struct CacheFindingRow: View {
    @Binding var finding: CacheFinding

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Image(systemName: finding.isSelected ? "checkmark.square.fill" : "square")
                .foregroundStyle(finding.isSelected ? .purple : .secondary)
                .font(.body)
                .onTapGesture { finding.isSelected.toggle() }

            // Path
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(finding.path)

                if let reason = finding.reason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Badges
            HStack(spacing: 6) {
                // Size
                Text(finding.size)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .cornerRadius(4)

                // Auto-regenerates
                if finding.regeneratesAutomatically {
                    Text("Auto-regenerates")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .cornerRadius(4)
                }

                // Source
                Text(finding.source.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(finding.source == .ai ? Color.purple.opacity(0.15) : Color.gray.opacity(0.15))
                    .foregroundStyle(finding.source == .ai ? .purple : .secondary)
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { finding.isSelected.toggle() }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    AIAnalysisView()
        .frame(width: 800, height: 600)
}
#endif
