import SwiftUI

@MainActor
struct UpdatesView: View {
    @StateObject private var service: UpdatesService
    @State private var reviewed: [PackageUpdate] = []
    @State private var showingReview = false

    init(administratorUpdate: MasAdministratorUpdate? = nil) {
        _service = StateObject(wrappedValue: UpdatesService(administratorUpdate: administratorUpdate))
    }

    private var isBusy: Bool { service.isChecking || service.isUpdating }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = service.errorMessage {
                MacSweepErrorBanner(message: error) { service.dismissError() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !service.hasChecked {
                        Text(
                            "Check manually to query installed package managers and their update sources. "
                                + "No package is upgraded until its commands are reviewed."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(UpdateSource.allCases, id: \.self) { source in sourceSection(source) }
                    if !service.outcomes.isEmpty { UpdateResultsPanel(outcomes: service.outcomes, log: service.log) }
                }.padding()
            }
        }
        .sheet(isPresented: $showingReview) {
            UpdatesReviewSheet(
                packages: reviewed, isRunning: service.isUpdating,
                outcomes: service.outcomes, log: service.log
            ) { acknowledgements in
                Task { await service.upgrade(reviewed, acknowledgements: acknowledgements) }
            }
        }
        .interactiveDismissDisabled(service.isUpdating)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Updates").font(.title).fontWeight(.bold)
                Text("Homebrew, App Store and global developer packages in one review.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Button("Check Updates", systemImage: "arrow.clockwise") { Task { await service.check() } }
                .glassButton(prominent: true).disabled(isBusy)
            Button("Review All Updates") {
                prepare(service.inventory.packages.filter(\.isEligible))
            }.glassButton().disabled(isBusy || !service.inventory.packages.contains(where: \.isEligible))
        }.padding().background(MacSweepTheme.panelStrong)
    }

    private func sourceSection(_ source: UpdateSource) -> some View {
        let packages = service.inventory.packages.filter { $0.source == source }
        let report = service.inventory.reports.first { $0.source == source }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(source.title).font(.headline)
                Spacer()
                if !packages.isEmpty {
                    Button("Review Group") { prepare(packages.filter(\.isEligible)) }
                        .disabled(isBusy || !packages.contains(where: \.isEligible))
                }
            }
            if let report {
                Label(report.message, systemImage: report.isError ? "exclamationmark.triangle" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not checked yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(packages) { package in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(package.version.title).fontWeight(.medium)
                        Text(package.version.current + " → " + package.version.latest)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let reason = package.blockedReason {
                            Label(reason, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        } else if package.requiresAdministrator {
                            Text("Administrator authorization and App Store sign-in required.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Review Update") { prepare([package]) }.disabled(isBusy || !package.isEligible)
                }.padding(.vertical, 5)
            }
            if source == .mas, let url = URL(string: "macappstore://showUpdatesPage") {
                Link("Open App Store Updates", destination: url).font(.caption)
            }
        }.padding().macSweepCard()
    }

    private func prepare(_ packages: [PackageUpdate]) {
        guard !packages.isEmpty else { return }
        reviewed = packages
        showingReview = true
    }
}
