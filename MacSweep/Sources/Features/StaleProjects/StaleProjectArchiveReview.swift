import SwiftUI

struct StaleProjectArchivePlan: Identifiable {
    let id = UUID()
    let project: StaleProject
    let destination: URL
}

struct StaleProjectArchiveReview: View {
    let plan: StaleProjectArchivePlan
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Review Project Archive", systemImage: "archivebox").font(.title2).bold()
            Text("Create a ZIP copy of the complete checkout. The source stays in place.")
            GroupBox("Source") { Text(plan.project.path.path).frame(maxWidth: .infinity, alignment: .leading) }
            GroupBox("Destination") { Text(plan.destination.path).frame(maxWidth: .infinity, alignment: .leading) }
            Text("Total source estimate: " + (plan.project.totalBytes?.formattedFileSize ?? "unknown")
                + ". Extra working space is needed for the ZIP and a complete verification extraction.")
            Text("Verification includes ignored and untracked files, Git metadata, content hashes, symlinks, "
                + "extended attributes, resource forks and permissions. Unsupported content, changing files, "
                +
                "protection rules and verification limits stop the archive. Existing destinations are never replaced.")
            Text("Native commands: ditto ZIP creation → unzip -tqq → ditto extraction → full manifest comparison.")
                .font(.caption).foregroundStyle(.secondary)
            if plan.project.git.isClean != true {
                Label("Dirty or unknown Git state. Archive creation is allowed; checkout Trash stays locked.",
                      systemImage: "exclamationmark.triangle")
            }
            if let reason = plan.project.git.trashBlocker {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Create and Verify ZIP", systemImage: "archivebox", action: onConfirm)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 640).textSelection(.enabled)
    }
}
