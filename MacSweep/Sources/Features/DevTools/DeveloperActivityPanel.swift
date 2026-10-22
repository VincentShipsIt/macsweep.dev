import SwiftUI

struct DeveloperActivityPanel: View {
    let items: [CleanupItem]
    let rescan: () async -> Void
    @State private var isExpanded = true
    @State private var selection = Set<DevProcessIdentity>()
    @State private var showingConfirmation = false
    @State private var isStopping = false
    @State private var errorMessage: String?

    private var jobs: [DevProcessJob] {
        var seen = Set<DevProcessIdentity>()
        return items.flatMap { $0.devArtifactReceipt?.blockers ?? [] }
            .filter { seen.insert($0.identity).inserted }.sorted { $0.identity.pid < $1.identity.pid }
    }

    var body: some View {
        if !jobs.isEmpty {
            DisclosureGroup("Jobs protecting developer artifacts (\(jobs.count))", isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Artifacts in use are retained. "
                            + "Stop only the developer jobs you select, then review a fresh scan."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(jobs) { job in
                                let canStop = DevProcessSnapshot(jobs: jobs).canStop(job)
                                Toggle(
                                    isOn: Binding(
                                        get: { selection.contains(job.identity) },
                                        set: { selected in
                                            if selected {
                                                selection.insert(job.identity)
                                            } else {
                                                selection.remove(job.identity)
                                            }
                                        }
                                    )
                                ) {
                                    VStack(alignment: .leading) {
                                        Text(job.label)
                                        Text(
                                            canStop
                                                ? job.directory.path
                                                : "Retained job — stop it in its owning app if needed"
                                        )
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(!canStop || isStopping)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                    Button("Stop Selected Developer Jobs") { showingConfirmation = true }
                        .disabled(selection.isEmpty || isStopping)
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .confirmationDialog("Stop the selected developer jobs?", isPresented: $showingConfirmation) {
                Button("Stop Selected Jobs", role: .destructive) {
                    let selected = jobs.filter { selection.contains($0.identity) }
                    Task {
                        isStopping = true
                        let errors = await DevProcessActivity.stop(selected: selected)
                        selection = []
                        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                        await rescan()
                        isStopping = false
                    }
                }
            } message: {
                Text(
                    "Only the selected verified developer jobs are asked to stop. "
                        + "Imports, unselected jobs and unknown descendants are retained. "
                        + "Cleanup remains a separate confirmed action after rescanning."
                )
            }
        }
    }
}
