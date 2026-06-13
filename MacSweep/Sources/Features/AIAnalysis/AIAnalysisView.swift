import SwiftUI

struct AIAnalysisView: View {
    @StateObject private var service = AIAnalysisService()
    @State private var apiKeyInput = ""
    @State private var hasApiKey = false
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
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            hasApiKey = AIKeychainService.shared.loadKey() != nil
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
                Text("Claude-powered cache scanner")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // API key status
            Button {
                showKeyField.toggle()
            } label: {
                Label(hasApiKey ? "API Key ✓" : "Add API Key", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(hasApiKey ? .green : .orange)
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
    }

    // MARK: - API Key Popover

    private var apiKeyPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude API Key")
                .font(.headline)

            Text("Stored securely in the macOS Keychain. Never written to disk in plain text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 280)

            Text("When AI analysis runs, item details — names, paths, sizes, and metadata — are sent to Anthropic's API (api.anthropic.com) for evaluation. File contents are never uploaded. Leave the key empty to keep all analysis on-device.")
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
                        hasApiKey = false
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
                        hasApiKey = true
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

                Text("Click Scan to find cache directories.\nPhase 1 is instant. Phase 2 uses Claude API for deeper analysis.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !hasApiKey {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                    Text("Add a Claude API key for AI-powered deep scan")
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
        .background(Color.purple.opacity(0.08))
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
        .background(Color(NSColor.windowBackgroundColor))
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
            // every other cleanup path before anything is touched.
            guard safety.validateForCleanup(url).isSafe else {
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
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
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
