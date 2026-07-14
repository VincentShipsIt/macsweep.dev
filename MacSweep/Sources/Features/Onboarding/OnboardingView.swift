import SwiftUI
import AppKit

/// Onboarding view shown on first launch
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage: Int
    @State private var hasFullDiskAccess: Bool
    @State private var fdaTimer: Timer?
    /// Shared identity for the trailing primary button so its glass capsule
    /// morphs (rather than hard-cuts) as the label/role changes across pages
    /// ("Next" → "Get Started" / "Continue Anyway"). WWDC25 guidance for a
    /// same-slot control with changing content.
    @Namespace private var primaryNavGlass

    init(
        isPresented: Binding<Bool>,
        initialPage: Int = 0,
        initialFullDiskAccess: Bool = FullDiskAccess.hasAccess
    ) {
        self._isPresented = isPresented
        self._currentPage = State(initialValue: initialPage)
        self._hasFullDiskAccess = State(initialValue: initialFullDiskAccess)
    }

    private let welcomePages: [OnboardingPage] = [
        OnboardingPage(
            icon: "sparkles",
            iconColor: .purple,
            title: "Welcome to MacSweep",
            description: "Keep your Mac clean, fast, and organized with powerful cleanup tools.",
            features: [
                ("trash.circle", "Remove junk files and caches"),
                ("app.badge.checkmark", "Uninstall apps completely"),
                ("chart.pie", "Visualize disk usage"),
                ("hammer", "Clean developer artifacts")
            ]
        ),
        OnboardingPage(
            icon: "shield.checkered",
            iconColor: .green,
            title: "Safe & Secure",
            description: "MacSweep protects your important files and never deletes anything without your permission.",
            features: [
                ("lock.shield", "Protected paths are never touched"),
                ("eye", "Preview before you delete"),
                ("trash", "Items go to Trash first"),
                ("arrow.uturn.backward", "Easy to restore if needed")
            ]
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                ForEach(welcomePages.enumerated(), id: \.element.id) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }

                // Special FDA permission page
                FDAPermissionPageView(hasAccess: hasFullDiskAccess)
                    .tag(welcomePages.count)
            }
            .tabViewStyle(.automatic)

            Divider()

            // Bottom bar
            HStack {
                // Page indicator
                HStack(spacing: 8) {
                    ForEach(0..<(welcomePages.count + 1), id: \.self) { index in
                        Circle()
                            .fill(currentPage == index ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                // Navigation buttons
                if currentPage > 0 {
                    Button("Back") {
                        changePage(to: currentPage - 1)
                    }
                    .glassButton()
                }

                // Both branches occupy the same slot and share one glassEffectID,
                // so the glass capsule morphs between them instead of hard-cutting.
                // The animation is gated on reduce-motion; when motion is reduced
                // the state swap is instant.
                GlassEffectContainer {
                    if currentPage < welcomePages.count {
                        primaryNavButton("Next", tint: .accentColor) {
                            changePage(to: currentPage + 1)
                        }
                    } else {
                        primaryNavButton(
                            hasFullDiskAccess ? "Get Started" : "Continue Anyway",
                            tint: hasFullDiskAccess ? .accentColor : .orange
                        ) {
                            isPresented = false
                        }
                    }
                }
                .animation(reduceMotion ? nil : .smooth, value: currentPage)
                .animation(reduceMotion ? nil : .smooth, value: hasFullDiskAccess)
            }
            .padding()
        }
        .frame(width: 650, height: 550)
        .onAppear {
            // Check permission status periodically. Invalidate any prior timer
            // first so repeated onAppear (sheet re-presented) can't stack parallel
            // 1s pollers, and store the reference so onDisappear can stop it.
            fdaTimer?.invalidate()
            fdaTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                hasFullDiskAccess = FullDiskAccess.hasAccess
                if !isPresented {
                    timer.invalidate()
                }
            }
        }
        .onDisappear {
            fdaTimer?.invalidate()
            fdaTimer = nil
        }
    }

    private func changePage(to page: Int) {
        if reduceMotion {
            currentPage = page
        } else {
            withAnimation {
                currentPage = page
            }
        }
    }

    /// The trailing primary CTA rendered as a custom glass capsule (rather than the
    /// native `.glassProminent` button style) so it can carry a `glassEffectID` and
    /// morph across page states. The glass value is still built through the
    /// centralized `LiquidGlass` factory.
    private func primaryNavButton(
        _ title: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(minWidth: 96)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(LiquidGlass.make(tint: tint, interactive: true), in: Capsule())
        .glassEffectID("onboarding.primaryNav", in: primaryNavGlass)
    }
}

// MARK: - FDA Permission Page View

struct FDAPermissionPageView: View {
    let hasAccess: Bool

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    statusIcon
                    title
                    description

                    if !hasAccess {
                        instructions
                        actionButtons
                    } else {
                        successState
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(hasAccess ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                .frame(width: 84, height: 84)

            Image(systemName: hasAccess ? "checkmark.shield.fill" : "hand.raised.fill")
                .font(.system(size: 42))
                .foregroundStyle(hasAccess ? .green : .orange)
        }
    }

    private var title: some View {
        Text(hasAccess ? "You're All Set!" : "Full Disk Access Required")
            .font(.title)
            .fontWeight(.bold)
            .multilineTextAlignment(.center)
    }

    private var description: some View {
        Text(hasAccess
            ? "MacSweep has the permissions it needs to scan and clean your Mac."
            : "MacSweep needs Full Disk Access to scan protected folders like Safari data, Mail attachments, and system caches.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 500)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow these steps:")
                .font(.headline)

            FDAStepRow(
                step: 1,
                title: "Open System Settings",
                description: "Open Privacy & Security settings."
            )

            FDAStepRow(
                step: 2,
                title: "Find Full Disk Access",
                description: "Select Full Disk Access in the Privacy list."
            )

            FDAStepRow(
                step: 3,
                title: "Add this MacSweep app",
                description: "MacSweep may not appear automatically. Click + and choose the exact app that Finder reveals below."
            )

            FDAStepRow(
                step: 4,
                title: "Enable and relaunch",
                description: "Turn MacSweep on, then quit and reopen it if macOS asks."
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macSweepCard(radius: 12)
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                systemSettingsButton
                revealInFinderButton
            }

            VStack(spacing: 10) {
                systemSettingsButton
                revealInFinderButton
            }
        }
        .padding(.top, 2)
    }

    private var systemSettingsButton: some View {
        Button {
            FullDiskAccess.openSystemPreferences()
        } label: {
            Label("Open System Settings", systemImage: "gear")
                .frame(minWidth: 180)
        }
        .glassButton(prominent: true)
    }

    private var revealInFinderButton: some View {
        Button {
            revealAppInFinder()
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
                .frame(minWidth: 150)
        }
        .glassButton()
    }

    private var successState: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Full Disk Access is enabled")
                    .fontWeight(.medium)
            }
            .padding()
            .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            Text("You can now use all of MacSweep's features.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func revealAppInFinder() {
        if let appURL = Bundle.main.bundleURL as URL? {
            NSWorkspace.shared.selectFile(appURL.path, inFileViewerRootedAtPath: appURL.deletingLastPathComponent().path)
        }
    }
}

// MARK: - FDA Step Row

struct FDAStepRow: View {
    let step: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Step number
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 28, height: 28)

                Text("\(step)")
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Onboarding Page Model

struct OnboardingPage: Identifiable {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let features: [(icon: String, text: String)]

    var id: String { title }
}

// MARK: - Onboarding Page View

struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: page.icon)
                .font(.system(size: 64))
                .foregroundStyle(page.iconColor)

            // Title
            Text(page.title)
                .font(.largeTitle)
                .fontWeight(.bold)

            // Description
            Text(page.description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Features
            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.features, id: \.text) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.title3)
                            .foregroundStyle(page.iconColor)
                            .frame(width: 28)

                        Text(feature.text)
                            .font(.body)
                    }
                }
            }
            .padding()
            .macSweepCard(radius: 12)

            Spacer()
        }
        .padding()
    }
}

#if !SWIFT_PACKAGE
#Preview {
    OnboardingView(isPresented: .constant(true))
}

#endif
