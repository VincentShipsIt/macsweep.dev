import SwiftUI

extension View {
    /// Presents the shared review → execute → result flow used by cleanup pages.
    /// The async operation must return the factual `CleanupResult` produced by
    /// the existing engine. Returning nil dismisses the sheet and leaves the
    /// page's existing error surface responsible for the failure message.
    func cleanupReview(
        isPresented: Binding<Bool>,
        items: [CleanupItem],
        disposition: CleanupDisposition,
        note: String? = nil,
        additionalCount: Int = 0,
        additionalBytes: Int64 = 0,
        additionalModules: [String] = [],
        additionalPaths: [URL] = [],
        onConfirm: @escaping () async -> CleanupResult?
    ) -> some View {
        modifier(CleanupReviewModifier(
            isPresented: isPresented,
            items: items,
            disposition: disposition,
            note: note,
            additionalCount: additionalCount,
            additionalBytes: additionalBytes,
            additionalModules: additionalModules,
            additionalPaths: additionalPaths,
            onConfirm: onConfirm
        ))
    }
}

enum CleanupDisposition: Sendable {
    case trash
    case permanent
    case localCloudCopy
    case mixed
    case toolNative(String)

    var title: String {
        switch self {
        case .trash: return "Move to Trash"
        case .permanent: return "Delete Permanently"
        case .localCloudCopy: return "Remove Local Copies"
        case .mixed: return "Run Cleanup"
        case .toolNative: return "Run Tool Cleanup"
        }
    }

    var detail: String {
        switch self {
        case .trash:
            return "Selected files move to Trash and can be restored until Trash is emptied."
        case .permanent:
            return "Selected files are deleted permanently and cannot be restored from Trash."
        case .localCloudCopy:
            return "Downloaded local copies are evicted; the cloud originals remain available. "
                + "Provider caches may be deleted permanently."
        case .mixed:
            return "Each module uses its declared action. Some items move to Trash; "
                + "tool-managed caches or Trash contents may be removed permanently."
        case .toolNative(let detail):
            return detail
        }
    }

    var icon: String {
        switch self {
        case .trash: return "trash"
        case .permanent: return "trash.slash"
        case .localCloudCopy: return "icloud.and.arrow.up"
        case .mixed: return "checkmark.shield"
        case .toolNative: return "terminal"
        }
    }
}

struct CleanupReviewModifier: ViewModifier {
    @Binding var isPresented: Bool
    let items: [CleanupItem]
    let disposition: CleanupDisposition
    let note: String?
    let additionalCount: Int
    let additionalBytes: Int64
    let additionalModules: [String]
    let additionalPaths: [URL]
    let onConfirm: () async -> CleanupResult?

    @State private var isRunning = false
    @State private var result: CleanupResult?
    @State private var requestedCount = 0

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: reset) {
            CleanupReviewSheet(
                summary: summary,
                disposition: disposition,
                note: note,
                isRunning: isRunning,
                result: result,
                requestedCount: requestedCount,
                onCancel: { isPresented = false },
                onConfirm: runCleanup
            )
            .interactiveDismissDisabled(isRunning)
        }
    }

    private var summary: CleanupReviewSummary {
        CleanupReviewSummary(
            items: items,
            additionalCount: additionalCount,
            additionalBytes: additionalBytes,
            additionalModules: additionalModules,
            additionalPaths: additionalPaths
        )
    }

    private func runCleanup() {
        guard !isRunning else { return }
        requestedCount = summary.itemCount
        isRunning = true
        Task { @MainActor in
            let completed = await onConfirm()
            isRunning = false
            guard let completed else {
                isPresented = false
                return
            }
            result = completed
        }
    }

    private func reset() {
        isRunning = false
        result = nil
        requestedCount = 0
    }
}

private struct CleanupReviewSheet: View {
    let summary: CleanupReviewSummary
    let disposition: CleanupDisposition
    let note: String?
    let isRunning: Bool
    let result: CleanupResult?
    let requestedCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                resultView(result)
            } else {
                reviewView
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 560)
    }

    private var reviewView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: disposition.icon)
                    .font(.title)
                    .foregroundStyle(summary.exceedsConfirmationThreshold ? .orange : MacSweepTheme.accent)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review Cleanup")
                        .font(.title2.weight(.semibold))
                    Text("Nothing changes until you confirm this exact selection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        reviewMetric("Items", value: "\(summary.itemCount)")
                        reviewMetric("Space", value: summary.totalBytes.formattedFileSize)
                        reviewMetric("Modules", value: "\(summary.moduleCounts.count)")
                    }

                    reviewSection("Action") {
                        Label(disposition.title, systemImage: disposition.icon)
                            .font(.headline)
                        Text(disposition.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if let note {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if summary.exceedsConfirmationThreshold {
                        Label(
                            largeCleanupWarning,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .background(MacSweepTheme.warningPanel, in: RoundedRectangle(cornerRadius: 10))
                    }

                    reviewSection("Modules") {
                        ForEach(summary.moduleCounts, id: \.name) { module in
                            HStack {
                                Text(module.name)
                                Spacer()
                                Text("\(module.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }

                    reviewSection("Paths") {
                        ForEach(summary.paths.prefix(12), id: \.self) { path in
                            Text(path.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        if summary.paths.count > 12 {
                            Text("and \(summary.paths.count - 12) more…")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRunning)
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cleaning…")
                        .foregroundStyle(.secondary)
                }
                Button(disposition.title, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning || summary.itemCount == 0)
            }
            .padding(16)
        }
    }

    private func resultView(_ result: CleanupResult) -> some View {
        let skipped = max(0, requestedCount - result.itemsProcessed - result.errors.count)
        return VStack(spacing: 20) {
            Spacer()
            Image(systemName: result.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 54))
                .foregroundStyle(result.errors.isEmpty ? .green : .orange)
            Text(result.errors.isEmpty ? "Cleanup Complete" : "Cleanup Finished with Issues")
                .font(.title2.weight(.semibold))
            Text("Freed \(result.formattedBytesFreed)")
                .font(.title3)

            HStack(spacing: 12) {
                reviewMetric("Processed", value: "\(result.itemsProcessed)")
                reviewMetric("Skipped", value: "\(skipped)")
                reviewMetric("Errors", value: "\(result.errors.count)")
            }
            .frame(maxWidth: 440)

            if !result.errors.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(result.errors) { error in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(error.path.path)
                                    .font(.caption.monospaced())
                                Text(error.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding()
                .background(MacSweepTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 40)
            }

            Spacer()
            Button("Done", action: onCancel)
                .keyboardShortcut(.defaultAction)
                .glassButton(prominent: true)
                .padding(.bottom, 20)
        }
    }

    private func reviewMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(MacSweepTheme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private var largeCleanupWarning: String {
        "Large cleanup: this selection exceeds MacSweep's "
            + "\(DeletionGuard().confirmationThreshold.formattedFileSize) confirmation threshold. "
            + "The \(DeletionGuard().maxTotalSize.formattedFileSize) hard cap still applies at execution."
    }

    private func reviewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
