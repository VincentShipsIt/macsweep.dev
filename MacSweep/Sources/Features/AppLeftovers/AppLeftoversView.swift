import SwiftUI

struct AppLeftoversView: View {
    @State private var report = AppLeftoversReport()
    @State private var selected = Set<String>()
    @State private var isScanning = false
    @State private var didScan = false
    @State private var showingReview = false
    @State private var submitted: [OrphanedAppData] = []
    private let service = OrphanedAppDataService()

    /// One-time state seeds for snapshots; production starts with an explicit scan.
    init(snapshotReport: AppLeftoversReport? = nil) {
        _report = State(initialValue: snapshotReport ?? AppLeftoversReport())
        _didScan = State(initialValue: snapshotReport != nil)
    }

    var body: some View {
        FeaturePageShell(title: "App Leftovers", subtitle: "Review data from apps removed outside MacSweep.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(didScan ? "Scan Again" : "Scan Leftovers") { Task { await scan() } }
                        .disabled(isScanning)
                    if isScanning { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Review Selected…") {
                        submitted = report.findings.filter { selected.contains($0.id) && $0.isSelectable }
                        showingReview = true
                    }.disabled(selected.isEmpty || isScanning)
                }
                Text(
                    "Review only. Metadata-grounded findings older than 30 days can be selected. "
                        + "Settings and personal app data move to Trash; restore them from Finder if needed."
                )
                .font(.callout).foregroundStyle(.secondary)
                ForEach(report.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if didScan && report.findings.isEmpty {
                    ContentUnavailableView(
                        report.issues.isEmpty ? "No app leftovers found" : "Scan incomplete",
                        systemImage: report.issues.isEmpty ? "checkmark.shield" : "exclamationmark.shield",
                        description: Text("No findings were identified in the scanned Library folders."))
                } else {
                    List(report.findings) { finding in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(
                                "Select \(finding.path.lastPathComponent)",
                                isOn: Binding(
                                    get: { selected.contains(finding.id) },
                                    set: { value in
                                        if value { selected.insert(finding.id) } else { selected.remove(finding.id) }
                                    })
                            )
                            .labelsHidden().disabled(!finding.isSelectable || isScanning)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(finding.path.lastPathComponent).font(.headline)
                                Text(finding.path.path).font(.caption.monospaced()).textSelection(.enabled)
                                Text(
                                    "\(finding.category) · \(finding.confidence.rawValue) · "
                                        + (finding.nodes.isEmpty ? "Size unavailable" : finding.size.formattedFileSize)
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                if let modified = finding.modified {
                                    Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))").font(
                                        .caption)
                                } else {
                                    Text("Modification date unavailable").font(.caption)
                                }
                                Text(finding.evidence).font(.caption)
                                Text(
                                    finding.retentionReason
                                        ?? "Owner absent; review before moving this app data to Trash."
                                )
                                .font(.caption).foregroundStyle(finding.isSelectable ? Color.secondary : .orange)
                            }
                            Spacer()
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([finding.path]) }
                        }.padding(.vertical, 6)
                    }.listStyle(.inset)
                }
            }.padding()
        }
        .cleanupReview(
            isPresented: $showingReview, items: [], disposition: .trash,
            note:
                "These files may contain settings and personal app data. Trash does not free disk space until emptied.",
            additionalCount: submitted.count, additionalBytes: submitted.reduce(0) { $0 + $1.size },
            additionalModules: ["App Leftovers"], additionalPaths: submitted.map(\.path)
        ) {
            let result = await service.remove(submitted)
            await scan()
            return result
        }
    }

    @MainActor private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        selected = []
        report = await service.scan()
        didScan = true
        isScanning = false
    }
}
