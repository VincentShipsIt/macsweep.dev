import SwiftUI

/// One shared shell for every feature page so they stop drifting. The visible
/// page title lives in the sidebar or page content; this shell keeps title and
/// subtitle as accessibility metadata and owns one optional native toolbar
/// action cluster. Pre-scan landing views opt out because their hero already
/// carries the page title and call to action.
struct FeaturePageShell<Content: View>: View {
    let title: String
    let subtitle: String?
    var trailing: AnyView? = nil
    var hidesChrome: Bool = false
    /// Wrap `content` in a real `ScrollView` (an `NSScrollView`). REQUIRED whenever
    /// the content is a sparse, pure-SwiftUI layout with no scroll/table of its own
    /// — e.g. a `ScanLandingView` hero. Without an `NSScrollView` in the detail, the
    /// `NavigationSplitView` drops the sidebar's `NSTableView` backing and the whole
    /// menu goes blank and never recovers (see the sidebar-blackout memory). Leave
    /// `false` when the content already provides one (a `List`, `ScrollView`, or
    /// `HSplitView`) — wrapping those again would break their scrolling. For pages
    /// that swap between a hero and a results `List`, pass the empty-state condition
    /// (e.g. `scrolls: items.isEmpty`).
    var scrolls: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var hidesTitlebarChrome = false

    init(title: String,
         subtitle: String? = nil,
         trailing: AnyView? = nil,
         hidesChrome: Bool = false,
         scrolls: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.hidesChrome = hidesChrome
        self.scrolls = scrolls
        self.content = content
    }

    var body: some View {
        contentContainer
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .navigationTitle("")
        .navigationSubtitle("")
        .accessibilityLabel(title)
        .accessibilityHint(subtitle ?? "")
        .toolbar {
            if !shouldHideChrome, let trailing {
                ToolbarItem(placement: .primaryAction) {
                    trailing
                }
            }
        }
        .onPreferenceChange(FeaturePageChromeHiddenPreferenceKey.self) { hidesTitlebarChrome = $0 }
    }

    private var shouldHideChrome: Bool {
        hidesChrome || hidesTitlebarChrome
    }

    @ViewBuilder
    private var contentContainer: some View {
        if scrolls {
            // GeometryReader + minHeight keeps short/sparse content (a hero)
            // vertically centered, and lets it scroll if the window is shorter
            // than the content.
            //
            // The hero surface runs full-bleed behind the titlebar
            // (CleanMyMac-style): laying the scroll view inside the top safe
            // area would end the page surface at the toolbar's bottom edge,
            // where macOS draws a scroll-edge hairline that reads as a border
            // around the hero. Hiding the toolbar background removes that
            // hairline; the hero is vertically centered, so nothing lands
            // under the traffic lights.
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    content()
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct FeaturePageChromeHiddenPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// CleanMyMac-style pre-scan onboarding: a centered icon, title, a short
/// description of what the action does, and exactly ONE primary CTA. Swaps to a
/// progress view while a scan runs. Use this as the empty state for any
/// scan-driven page so the trigger is explained before it's pressed.
/// A benefit bullet on the scan landing: icon + bold benefit + one supporting line.
struct ScanBenefit: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    init(_ icon: String, _ title: String, _ detail: String) {
        self.icon = icon
        self.title = title
        self.detail = detail
    }
}

/// CleanMyMac-style pre-scan landing: a left column (title, description, benefit
/// bullets), a large illustration on the right, and a big glowing circular Scan
/// button centered at the bottom. Swaps to a progress view while scanning.
struct ScanLandingView: View {
    let icon: String
    let title: String
    let description: String
    let ctaTitle: String
    var benefits: [ScanBenefit] = []
    var illustration: String? = nil
    var isScanning: Bool = false
    var progress: Double = 0
    var scanningMessage: String? = nil
    var hidesPageChrome: Bool = true
    let action: () -> Void

    var body: some View {
        Group {
            if isScanning {
                ScanProgressStatusView(progress: progress, message: scanningMessage ?? "Scanning")
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            } else {
                // Centered focal block (vertically + horizontally), not stretched to the
                // full detail area. The sidebar-preserving scroll backing lives in
                // FeaturePageShell (see its body), so this stays a plain centered VStack
                // and composes cleanly as a feature page's scan-only starting state.
                VStack(spacing: 32) {
                    HStack(alignment: .center, spacing: 40) {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(title)
                                    .font(.system(size: 26, weight: .bold))
                                Text(description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            ForEach(benefits) { benefit in
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: benefit.icon)
                                        .font(.title3)
                                        .foregroundStyle(MacSweepTheme.accent)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(benefit.title)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                        Text(benefit.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)

                        Image(systemName: illustration ?? icon)
                            .font(.system(size: 128, weight: .ultraLight))
                            .foregroundStyle(MacSweepTheme.accent.opacity(0.92))
                    }

                    CircularScanButton(accessibilityLabel: ctaTitle, action: action)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            }
        }
        .preference(key: FeaturePageChromeHiddenPreferenceKey.self, value: hidesPageChrome)
    }
}

/// The signature CleanMyMac circular Scan button — a glowing accent ring.
struct CircularScanButton: View {
    var title: String = "Scan"
    var accessibilityLabel: String = "Start scan"
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(MacSweepTheme.panel)
                Circle()
                    .strokeBorder(MacSweepTheme.accent.opacity(0.95), lineWidth: 2)
                    .shadow(color: MacSweepTheme.accent.opacity(!reduceMotion && isHovering ? 0.7 : 0.45),
                            radius: !reduceMotion && isHovering ? 16 : 9)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .frame(width: 96, height: 96)
            .scaleEffect(!reduceMotion && isHovering ? 1.04 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Scans only. You can review results before anything is removed.")
        .help("\(accessibilityLabel) (Command-R)")
        .onHover { isHovering = $0 }
    }
}

struct MacSweepErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.caption)

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
            .accessibilityHint("Dismisses this message")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }
}
