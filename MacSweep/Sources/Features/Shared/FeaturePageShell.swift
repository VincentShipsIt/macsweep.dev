import SwiftUI

/// One shared shell for every feature page so they stop drifting (dark vs gray
/// headers, ad-hoc padding). The header is transparent — it sits on the app's
/// dark detail background (`MacSweepDetailBackground` from ContentView) — with a
/// title + one-line subtitle and an optional SINGLE trailing action. Page-level
/// primary actions belong in the content (e.g. `ScanLandingView`), not here, so
/// we never show a header CTA *and* a body CTA for the same thing.
struct FeaturePageShell<Content: View>: View {
    let title: String
    let subtitle: String?
    var trailing: AnyView? = nil
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

    init(title: String,
         subtitle: String? = nil,
         trailing: AnyView? = nil,
         scrolls: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.scrolls = scrolls
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let trailing {
                    trailing
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .overlay(MacSweepTheme.divider)

            if scrolls {
                // GeometryReader + minHeight keeps short/sparse content (a hero)
                // vertically centered, and lets it scroll if the window is shorter
                // than the content.
                GeometryReader { proxy in
                    ScrollView {
                        content()
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                }
            } else {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
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
    let action: () -> Void

    /// Drives the hero's own slide-up + fade entrance. Page switches themselves are
    /// an instant swap (see `ContentView`), so this local animation is what gives the
    /// onboarding screen its signature CleanMyMac-style rise — and it fires only when
    /// the hero actually appears (navigation *or* clearing back to empty), never for
    /// a results table or any content page.
    @State private var hasEntered = false

    var body: some View {
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

                CircularScanButton(action: action)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
            // Self-contained entrance: rise + fade in whenever the hero appears.
            .offset(y: hasEntered ? 0 : 28)
            .opacity(hasEntered ? 1 : 0)
            .onAppear {
                hasEntered = false
                withAnimation(.easeOut(duration: 0.4)) { hasEntered = true }
            }
        }
    }
}

/// The signature CleanMyMac circular Scan button — a glowing accent ring.
struct CircularScanButton: View {
    var title: String = "Scan"
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(MacSweepTheme.panel)
                Circle()
                    .strokeBorder(MacSweepTheme.accent.opacity(0.95), lineWidth: 2)
                    .shadow(color: MacSweepTheme.accent.opacity(isHovering ? 0.7 : 0.45),
                            radius: isHovering ? 16 : 9)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .frame(width: 96, height: 96)
            .scaleEffect(isHovering ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
