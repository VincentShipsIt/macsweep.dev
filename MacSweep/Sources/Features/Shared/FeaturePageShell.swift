import SwiftUI

/// One shared shell for every feature page so they stop drifting (dark vs gray
/// headers, ad-hoc padding). The header is transparent — it sits on the app's
/// dark detail background (`MacSweepDetailBackground` from ContentView) — with a
/// title + one-line subtitle and an optional SINGLE trailing action. Page-level
/// primary actions belong in the content (e.g. `ScanLandingView`), not here, so
/// we never show a header CTA *and* a body CTA for the same thing.
struct FeaturePageShell<Content: View>: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: () -> Content

    init(title: String,
         subtitle: String,
         trailing: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var body: some View {
        if isScanning {
            ScanProgressStatusView(progress: progress, message: scanningMessage ?? "Scanning")
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
        } else {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 22) {
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
                    .frame(maxWidth: 430, alignment: .leading)

                    Spacer(minLength: 0)

                    Image(systemName: illustration ?? icon)
                        .font(.system(size: 132, weight: .ultraLight))
                        .foregroundStyle(MacSweepTheme.accent.opacity(0.92))
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 28)

                CircularScanButton(action: action)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)
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
