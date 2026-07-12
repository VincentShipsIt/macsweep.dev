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
        FeaturePageShell(
            title: "AI Analysis",
            subtitle: "Claude/Codex-powered deep cache analysis.",
            trailing: AnyView(
                Button {
                    showKeyField.toggle()
                } label: {
                    Label(providerStatusLabel, systemImage: hasLocalAIProvider ? "terminal" : "key")
                        .foregroundStyle(hasLocalAIProvider || hasApiKey ? .green : .orange)
                }
                .glassButton()
                .controlSize(.small)
                .popover(isPresented: $showKeyField) {
                    apiKeyPopover
                }
            ),
            hidesChrome: false,
            scrolls: service.findings.isEmpty && !service.isScanning
        ) {
            if service.findings.isEmpty && !service.isScanning {
                ScanLandingView(
                    icon: "brain.head.profile",
                    title: "AI-Powered Cache Analysis",
                    description: "Phase 1 finds cache directories instantly; Phase 2 uses Claude or Codex CLI for deeper analysis.",
                    ctaTitle: "Scan with AI",
                    benefits: [
                        ScanBenefit("brain", "Smarter than a cache list", "Claude or Codex inspects each cache directory and explains what it is, so you reclaim space without guesswork."),
                        ScanBenefit("lock.shield", "Stays on your Mac", "Analysis runs through your signed-in Claude or Codex CLI, and nothing is removed until you review every finding."),
                    ],
                    illustration: "sparkle.magnifyingglass",
                    isScanning: service.isScanning,
                    progress: 0,
                    scanningMessage: service.phase,
                    action: { Task { await service.scan() } }
                )
            } else {
                resultsList

                Divider()

                bottomBar
            }
        }
        .onAppear {
            refreshProviderState()
        }
    }

    // MARK: - API Key Popover

    private var apiKeyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Anthropic API Key Fallback")
                .font(.headline)

            Text("macsweep.dev uses signed-in Claude or Codex CLIs first. A key is only needed as a fallback when local CLIs are unavailable.")
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
        Task {
            // Do the blocking trashItem I/O OFF the main thread (returns only
            // Sendable [String] arrays, so no @StateObject is captured by the
            // detached task), then apply UI mutations back on the main actor.
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> (deleted: [String], failed: [String], blocked: [String]) in
                var deleted: [String] = []
                var failed: [String] = []
                var blocked: [String] = []
                let safety = SafetyChecker()

                for path in pathsToDelete {
                    let url = URL(fileURLWithPath: path)

                    // AI suggestions are advisory — they MUST pass the same safety
                    // gate as every other cleanup path. The `ai-analysis` module id
                    // reaches the dedicated allow-zone (developer + AI-tool cache
                    // roots outside ~/Library/Caches); without it those findings
                    // fail closed and the feature's own results can't be cleaned.
                    guard safety.validateForCleanup(url, moduleID: "ai-analysis").isSafe else {
                        blocked.append(path)
                        continue
                    }

                    do {
                        // Recoverable: AI false positives are possible, so move to
                        // Trash rather than deleting outright.
                        try CleanupFileRemover.recoverable(url, module: "ai-analysis")
                        deleted.append(path)
                    } catch {
                        failed.append(path)
                    }
                }
                return (deleted, failed, blocked)
            }.value

            // Remove deleted items from findings
            service.findings.removeAll { outcome.deleted.contains($0.path) }

            var messages: [String] = []
            if !outcome.blocked.isEmpty {
                messages.append("\(outcome.blocked.count) item(s) blocked by safety checks")
            }
            if !outcome.failed.isEmpty {
                messages.append("\(outcome.failed.count) item(s) could not be moved to Trash (check permissions)")
            }
            if !messages.isEmpty {
                service.error = messages.joined(separator: "; ")
            }
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
        .background(.bar)
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
