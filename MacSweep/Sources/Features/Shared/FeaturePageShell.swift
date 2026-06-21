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
struct ScanLandingView: View {
    let icon: String
    let title: String
    let description: String
    let ctaTitle: String
    var isScanning: Bool = false
    var progress: Double = 0
    var scanningMessage: String? = nil
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if isScanning {
                ScanProgressStatusView(
                    progress: progress,
                    message: scanningMessage ?? "Scanning"
                )
                .frame(maxWidth: 360)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 50, weight: .regular))
                    .foregroundStyle(MacSweepTheme.accent)
                    .padding(.bottom, 2)

                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)

                Button(ctaTitle, action: action)
                    .glassButton(prominent: true)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
