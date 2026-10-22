import SwiftUI

struct EditorCachesView: View {
    @State private var report: EditorCachesReport
    @State private var didScan: Bool
    @State private var selected = Set<String>()
    @State private var submitted: [EditorCacheFinding] = []
    @State private var scanning = false
    @State private var showingReview = false
    private let service = EditorCachesService()

    /// Snapshot seeds are one-time presentation state; production starts with an explicit scan.
    init(snapshotReport: EditorCachesReport? = nil) {
        _report = State(initialValue: snapshotReport ?? EditorCachesReport())
        _didScan = State(initialValue: snapshotReport != nil)
    }

    var body: some View {
        FeaturePageShell(title: "IDE & Editor Caches", subtitle: "Review stale IDE versions and editor caches.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(didScan ? "Scan Again" : "Scan Editor Caches") { Task { await scan() } }
                        .disabled(scanning)
                    if scanning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Review Selected…") {
                        submitted = report.findings.filter { selected.contains($0.id) && $0.isSelectable }
                        showingReview = true
                    }.disabled(scanning || selected.isEmpty)
                }
                .buttonStyle(.bordered)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Review only. Quit the owning app first. Caches rebuild on next launch; "
                        + "old workspace state "
                        + "and extension files move to Trash. "
                        + "Settings, keymaps, Local History and backups are retained."
                )
                .font(.callout).foregroundStyle(.secondary)
                ForEach(report.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if didScan && report.findings.isEmpty {
                    ContentUnavailableView(
                        report.issues.isEmpty ? "No editor caches found" : "Scan incomplete",
                        systemImage: report.issues.isEmpty ? "checkmark.shield" : "exclamationmark.shield",
                        description: Text(
                            "Only known IDE, editor and allowlisted Electron cache locations are inspected."))
                } else {
                    List(report.findings) { finding in
                        EditorCacheRow(
                            finding: finding,
                            selected: Binding(
                                get: { selected.contains(finding.id) },
                                set: { value in
                                    if value { selected.insert(finding.id) } else { selected.remove(finding.id) }
                                }), scanning: scanning)
                    }.listStyle(.inset)
                }
            }.padding()
        }
        .cleanupReview(
            isPresented: $showingReview, items: [], disposition: .trash,
            note: "Electron caches rebuild on next launch. Old editor state and extension folders move to Trash. "
                + "Trash does not free disk space until emptied.",
            additionalCount: submitted.count, additionalBytes: submitted.reduce(0) { $0 + $1.size },
            additionalModules: ["IDE & Editor Caches"], additionalPaths: submitted.map { $0.candidate.path }
        ) {
            let result = await service.remove(submitted)
            await scan()
            return result
        }
    }

    @MainActor private func scan() async {
        guard !scanning else { return }
        scanning = true
        selected = []
        report = await service.scan()
        didScan = true
        scanning = false
    }
}

private struct EditorCacheRow: View {
    let finding: EditorCacheFinding
    @Binding var selected: Bool
    let scanning: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(finding.candidate.path.lastPathComponent)", isOn: $selected)
                .labelsHidden().disabled(!finding.isSelectable || scanning)
            VStack(alignment: .leading, spacing: 4) {
                Text(finding.candidate.owner + " · " + finding.candidate.path.lastPathComponent).font(.headline)
                Text(finding.candidate.path.path).font(.caption.monospaced()).textSelection(.enabled)
                Text(
                    finding.candidate.kind.rawValue + " · "
                        + (finding.nodes.isEmpty ? "Size unavailable" : finding.size.formattedFileSize)
                )
                .font(.caption).foregroundStyle(.secondary)
                if let modified = finding.modified {
                    Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                } else {
                    Text("Modification date unavailable").font(.caption)
                }
                Text(finding.candidate.evidence).font(.caption)
                Text(finding.retentionReason ?? "Exact stale-cache evidence; review before moving to Trash.")
                    .font(.caption).foregroundStyle(finding.isSelectable ? Color.secondary : .orange)
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([finding.candidate.path]) }
        }.padding(.vertical, 6)
    }
}
