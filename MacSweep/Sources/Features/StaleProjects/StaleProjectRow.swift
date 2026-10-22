import SwiftUI

struct StaleProjectRow: View {
    let project: StaleProject
    @Binding var selected: Set<UUID>
    let disabled: Bool
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(project.path.lastPathComponent, systemImage: "folder").font(.headline)
                Text(project.age.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Archive ZIP…", systemImage: "archivebox", action: onArchive)
                    .disabled(disabled || project.archiveBlocker != nil)
            }
            Text(project.path.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 20) {
                metric("Source & retained data", bytes: project.sourceBytes)
                metric("Verified artifacts", bytes: project.artifactBytes)
                metric("Total estimate", bytes: project.totalBytes)
            }
            HStack(spacing: 20) {
                date("Last commit", project.git.lastCommit)
                date("Last file change", project.lastFileModification)
                date("Last checkout", project.git.lastCheckout)
            }
            Text("Remote: " + (project.git.remote ?? "Unavailable")
                + " · Git: " + gitFlags).font(.caption).textSelection(.enabled)
            Text("Remote coverage uses local remote-tracking refs; it does not fetch or verify a server backup.")
                .font(.caption).foregroundStyle(.secondary)
            if let blocker = project.archiveBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(project.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if !project.artifacts.isEmpty {
                Divider()
                ForEach(project.artifacts) { item in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(
                            get: { selected.contains(item.id) },
                            set: {
                                if $0 {
                                    selected.insert(item.id)
                                } else {
                                    selected.remove(item.id)
                                }
                            },
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.path.lastPathComponent + " · " + item.size.formattedFileSize)
                                Text(item
                                    .cleanupReviewReason ?? "Verified artifact; moves to Trash after fresh checks.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(disabled || item.devArtifactReceipt?.isEligible != true)
                    }
                }
            }
        }.padding().macSweepCard()
    }

    private var gitFlags: String {
        let dirty = project.git.isClean.map { $0 ? "clean" : "dirty" } ?? "unknown"
        let unpushed = project.git.unpushedCommits.map { "\($0) local-only commits" } ?? "unpushed unknown"
        return dirty + ", " + unpushed
    }

    private func metric(_ label: String, bytes: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(bytes?.formattedFileSize ?? "Unknown").font(.callout).monospacedDigit()
        }
    }

    private func date(_ label: String, _ value: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown").font(.caption)
        }
    }
}
