import SwiftUI

struct PrivacyCategoryCard: View {
    let category: String
    let items: [CleanupItem]
    let isSelected: Bool
    let isExpanded: Bool
    let onSelectionToggle: () -> Void
    let onExpansionToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    private var icon: String {
        if category.contains("Recent Documents") { return "doc.text" }
        if category.contains("Recent Applications") { return "app.badge" }
        if category.contains("Saved State") { return "square.stack.3d.up" }
        if category.contains("Download") || category.contains("Quarantine") {
            return "arrow.down.circle"
        }
        if category.contains("Server") { return "server.rack" }
        if category.contains("Host") { return "network" }
        return "hand.raised"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                selectionButton
                expansionButton
            }
            .padding()

            if isExpanded {
                Divider()
                evidenceRows
            }
        }
        .background(
            RoundedRectangle(cornerRadius: MacSweepTheme.mediumRadius)
                .fill(isSelected ? MacSweepTheme.selectionFill : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacSweepTheme.mediumRadius)
                .stroke(
                    isSelected ? MacSweepTheme.selection : MacSweepTheme.cardStroke,
                    lineWidth: 1
                )
        )
    }

    private var selectionButton: some View {
        Button(action: onSelectionToggle) {
            SelectionCheckmark(isSelected: isSelected)
                .font(.title2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Deselect \(category)" : "Select \(category)")
        .accessibilityHint("Changes which Privacy category will be moved to Trash.")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var expansionButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                onExpansionToggle()
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(MacSweepTheme.accentPurple)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category)
                        .font(.headline)

                    Text("\(items.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(totalSize.formattedFileSize)
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(category), \(items.count) items, \(totalSize.formattedFileSize)"
        )
        .accessibilityValue(isExpanded ? "Details shown" : "Details hidden")
        .accessibilityHint(
            isExpanded
                ? "Hides individual Privacy artifacts."
                : "Shows individual Privacy artifacts."
        )
    }

    private var evidenceRows: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                PrivacyItemEvidenceRow(item: item)

                if item.id != items.last?.id {
                    Divider()
                        .padding(.leading, 48)
                }
            }
        }
    }
}

private struct PrivacyItemEvidenceRow: View {
    let item: CleanupItem

    private var evidence: PrivacyItemEvidence {
        PrivacyItemEvidence(item: item)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(evidence.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                metadata

                Label(evidence.reviewReason, systemImage: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var metadata: some View {
        HStack(spacing: 14) {
            Label(evidence.formattedSize, systemImage: "internaldrive")

            switch evidence.modification {
            case .date(let date):
                Label {
                    Text(date, style: .date)
                } icon: {
                    Image(systemName: "calendar")
                }
            case .unavailable:
                Label(
                    "Modified date unavailable",
                    systemImage: "calendar.badge.exclamationmark"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

#if !SWIFT_PACKAGE
#Preview("Privacy Results") {
    PrivacyView(snapshotItems: [
        CleanupItem(
            id: UUID(),
            path: URL(fileURLWithPath: "/Users/you/Library/Safari/Downloads.plist"),
            size: 24_576,
            type: .file,
            module: "privacy",
            moduleName: "Safari Downloads History",
            lastModified: Date(timeIntervalSince1970: 1_782_300_600),
            cleanupReviewReason: PrivacyModule.cleanupReviewReason
        )
    ])
    .environmentObject(AppState())
    .frame(width: 600, height: 700)
}
#endif
