import SwiftUI

struct CleanupHistoryView: View {
    @State private var runs: [CleanupHistoryRun] = []

    private let store = CleanupHistoryStore.shared
    private let loadsPersistentHistory: Bool

    init(snapshotRuns: [CleanupHistoryRun]? = nil) {
#if SWIFT_PACKAGE
        // The headless renderer compiles the GUI with SWIFT_PACKAGE. Never read
        // a developer's real history while producing deterministic snapshots.
        loadsPersistentHistory = false
        _runs = State(initialValue: snapshotRuns ?? [])
#else
        loadsPersistentHistory = snapshotRuns == nil
        _runs = State(initialValue: snapshotRuns ?? [])
#endif
    }

    var body: some View {
        FeaturePageShell(
            title: "Cleanup History",
            subtitle: "A factual, on-device record of recent cleanup activity",
            trailing: AnyView(refreshButton)
        ) {
            Group {
                if runs.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .macSweepListSurface()
        }
        .onAppear {
            if loadsPersistentHistory {
                refresh()
            }
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Label("Refresh History", systemImage: "arrow.clockwise")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Cleanup History", systemImage: "clock.arrow.circlepath")
        } description: {
            Text(
                "Completed and failed cleanup attempts will appear here. "
                    + "Dry runs are never recorded as cleanup activity."
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                recoveryNotice

                ForEach(runs.reversed()) { run in
                    CleanupHistoryRunView(run: run)
                }
            }
            .padding(24)
        }
    }

    private var recoveryNotice: some View {
        Label {
            Text(
                "Items marked **Moved to Trash** can be restored in Finder: open Trash, "
                    + "find the item, then choose Put Back. The original path is recorded below."
            )
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacSweepTheme.warningPanel, in: RoundedRectangle(cornerRadius: 12))
    }

    private func refresh() {
        runs = store.history
    }
}

private struct CleanupHistoryRunView: View {
    let run: CleanupHistoryRun

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(run.bytesCompleted.formattedFileSize)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(MacSweepTheme.accent)
            }

            Divider()

            ForEach(run.records) { record in
                CleanupHistoryRecordView(record: record)
                if record.id != run.records.last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .macSweepCard(radius: 12)
    }

    private var summary: String {
        let completed = "\(run.completedCount) completed"
        guard run.failedCount > 0 else { return completed }
        return "\(completed), \(run.failedCount) failed"
    }
}

private struct CleanupHistoryRecordView: View {
    let record: CleanupHistoryRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.outcome == .completed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(record.outcome == .completed ? MacSweepTheme.accent : .orange)
                .accessibilityLabel(record.outcome == .completed ? "Completed" : "Failed")

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(record.displayName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Text(record.bytes.formattedFileSize)
                        .foregroundStyle(.secondary)
                }

                Text("\(record.moduleName) · \(record.action.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(record.originalPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)

                if let errorMessage = record.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
