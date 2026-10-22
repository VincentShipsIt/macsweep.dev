import SwiftUI

struct UpdatesReviewSheet: View {
    let packages: [PackageUpdate]
    let isRunning: Bool
    let outcomes: [UpdateOutcome]
    let log: String
    let onConfirm: (UpdateAcknowledgements) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var administratorAcknowledged = false
    @State private var signedInAcknowledged = false
    @State private var didStart = false

    private var needsAdministrator: Bool { packages.contains(where: \.requiresAdministrator) }
    private var canStart: Bool { !needsAdministrator || administratorAcknowledged && signedInAcknowledged }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(didStart ? "Update Results" : "Review Updates").font(.title2).fontWeight(.semibold)
            if didStart {
                if isRunning { ProgressView("Running native update commands…") }
                UpdateResultsPanel(outcomes: outcomes, log: log)
            } else {
                review
            }
            HStack {
                Spacer()
                Button(didStart ? "Done" : "Cancel") { dismiss() }.disabled(isRunning)
                if !didStart {
                    Button("Run Reviewed Updates") {
                        didStart = true
                        onConfirm(
                            .init(administrator: administratorAcknowledged, appStoreSignedIn: signedInAcknowledged))
                    }.glassButton(prominent: true).disabled(!canStart || isRunning)
                }
            }
        }.padding(24).frame(minWidth: 640, idealWidth: 720, minHeight: 360)
            .interactiveDismissDisabled(isRunning)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                "Updates can replace installed software and dependencies. Native installers may run package code. "
                    + "Homebrew runs with sudo disabled; npm/pnpm lifecycle scripts are disabled. "
                    + "pipx accepts binary wheels only. "
                    + "RubyGems may build extensions in its writable install location."
            )
            .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(packages) { package in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                package.version.title + ": " + package.version.current + " → " + package.version.latest
                            )
                            .fontWeight(.medium)
                            Text(package.command.preview).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 280)
            if needsAdministrator {
                Text(
                    "App Store updates run first. macOS will request administrator authorization before a reviewed "
                        + "App Store update begins. Declining it records a failure. "
                        + "Sign-in is managed in the App Store."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("I expect the macOS administrator authorization prompt", isOn: $administratorAcknowledged)
                Toggle("I am signed in to the required Apple Account in the App Store", isOn: $signedInAcknowledged)
            }
        }
    }
}

struct UpdateResultsPanel: View {
    let outcomes: [UpdateOutcome]
    let log: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !outcomes.isEmpty {
                Text(
                    "\(outcomes.filter(\.succeeded).count) completed, "
                        + "\(outcomes.filter { !$0.succeeded }.count) failed or retained"
                )
                .font(.headline)
                ForEach(outcomes) { outcome in
                    Label(
                        outcome.update.version.title + ": " + outcome.message,
                        systemImage: outcome.succeeded ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !log.isEmpty {
                ScrollView {
                    Text(log).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 120, maxHeight: 280).padding(10).macSweepCard()
            }
        }
    }
}
