import SwiftUI

// Shared building blocks for the scan-feature result pages. FeaturePageShell
// already hosts the pre-scan landing and error chrome; these cover the
// post-scan surface — selectable rows, the selection/clean footer, the toolbar
// Rescan button, and the "nothing found" state — that every cleanup page used
// to hand-copy. Rows and footers that genuinely differ (card-embedded buttons,
// inline detail blocks, bespoke button clusters) keep their own layout; these
// are for the common shapes, not a straitjacket.

// MARK: - Selection checkmark

/// The circle / filled-checkmark selection glyph shared by every selectable row.
/// Routes its tint through `MacSweepTheme.selection` so the accent lives in one
/// place. Pass `onToggle` for rows whose checkmark is individually tappable.
struct SelectionCheckmark: View {
    let isSelected: Bool
    var onToggle: (() -> Void)? = nil

    var body: some View {
        let image = Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? MacSweepTheme.selection : .secondary)
        if let onToggle {
            Button(action: onToggle) {
                image
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Selection")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
        } else {
            image
                .accessibilityLabel("Selection")
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
        }
    }
}

// MARK: - Selectable row

/// The shared skeleton behind a selectable results row: a selection checkmark, a
/// leading type glyph, the item's title/subtitle column, a `Spacer`, and a
/// trailing size / action cluster — all in an `HStack(spacing: 12)` with
/// `.padding(.vertical, 4)`. Callers fill the three slots and apply any
/// row-specific outer modifiers (`.contentShape`, `.opacity`, whole-row tap).
struct SelectableItemRow<Leading: View, Content: View, Trailing: View>: View {
    let isSelected: Bool
    var onToggle: (() -> Void)? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    init(
        isSelected: Bool,
        onToggle: (() -> Void)? = nil,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.isSelected = isSelected
        self.onToggle = onToggle
        self.leading = leading
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            SelectionCheckmark(isSelected: isSelected, onToggle: onToggle)
            leading()
            content()
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Cleanup footer

/// The leading "N selected / Will free <size>" column shared by every cleanup
/// footer. Exposed on its own so pages with a bespoke button cluster can still
/// reuse the summary.
struct CleanupFooterSummary: View {
    let selectedCount: Int
    var totalCount: Int? = nil
    var countNoun: String? = nil
    /// The "Will free 1.2 GB" headline. `nil` omits it (e.g. SSH hosts, which
    /// have no reclaimable size).
    var summary: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selectionText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let summary {
                Text(summary)
                    .font(.headline)
            }
        }
    }

    private var selectionText: String {
        if let totalCount {
            return "\(selectedCount) of \(totalCount) selected"
        }
        if let countNoun {
            return "\(selectedCount) \(countNoun) selected"
        }
        return "\(selectedCount) selected"
    }
}

/// The standard cleanup footer: a selection summary on the left, then a
/// `Select All` button and one prominent destructive action on the right. Only
/// the summary noun, the verb in `summary`, and the action label/tint vary
/// between pages. Attach the confirmation with `.deleteConfirmation(...)`.
struct CleanupFooter: View {
    let selectedCount: Int
    var totalCount: Int? = nil
    var countNoun: String? = nil
    let summary: String
    var selectAllTitle: String = "Select All"
    let onSelectAll: () -> Void
    let actionTitle: String
    /// Tint for the destructive action. `nil` leaves the prominent glass style
    /// untinted (e.g. Cloud Cleanup's "Reclaim Space").
    var actionTint: Color? = .red
    let actionDisabled: Bool
    let onAction: () -> Void
    /// Some footers sit on a `panelStrong` bar (System Junk, Package Managers).
    var showsPanelBackground: Bool = false

    var body: some View {
        HStack {
            CleanupFooterSummary(
                selectedCount: selectedCount,
                totalCount: totalCount,
                countNoun: countNoun,
                summary: summary
            )

            Spacer()

            Button(selectAllTitle, action: onSelectAll)
                .glassButton()

            actionButton
        }
        .padding()
        .modifier(FooterBackground(active: showsPanelBackground))
    }

    @ViewBuilder
    private var actionButton: some View {
        let button = Button(actionTitle, action: onAction)
            .glassButton(prominent: true)
        if let actionTint {
            button.tint(actionTint).disabled(actionDisabled)
        } else {
            button.disabled(actionDisabled)
        }
    }
}

private struct FooterBackground: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.background(MacSweepTheme.panelStrong)
        } else {
            content
        }
    }
}

extension View {
    /// The shared destructive confirmation dialog: a `.visible` title, one
    /// `.destructive` confirm button, and a Cancel. Replaces the
    /// `confirmationDialog { destructive; cancel } message:` block that every
    /// cleanup page copied.
    func deleteConfirmation(
        _ title: String,
        isPresented: Binding<Bool>,
        confirmTitle: String,
        message: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirmTitle, role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

// MARK: - Rescan toolbar button

/// The `FeaturePageShell` trailing "Rescan" action — a small secondary glass
/// button with the refresh glyph, disabled while a scan runs. `title` defaults
/// to "Rescan" but a few pages relabel it ("Check Updates").
struct RescanButton: View {
    var title: String = "Rescan"
    let isScanning: Bool
    var usesNativeToolbarStyle = false
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if usesNativeToolbarStyle {
            button
        } else {
            button.glassButton()
        }
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .disabled(isScanning)
    }
}

// MARK: - Empty result state

/// The centered "nothing found" state a scan page shows once it has scanned but
/// come up empty. `fillsSpace` (the default) centers it in the whole detail
/// area; pass `false` when it sits inline above other sections.
struct EmptyResultState: View {
    let icon: String
    let title: String
    let message: String
    var iconColor: Color = MacSweepTheme.accent
    var fillsSpace: Bool = true
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.title3)
                .fontWeight(.semibold)

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "arrow.clockwise")
                }
                .glassButton()
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: fillsSpace ? 360 : .infinity)
        .modifier(EmptyResultLayout(fillsSpace: fillsSpace))
    }
}

private struct EmptyResultLayout: ViewModifier {
    let fillsSpace: Bool

    func body(content: Content) -> some View {
        if fillsSpace {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
        } else {
            content
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }
}
