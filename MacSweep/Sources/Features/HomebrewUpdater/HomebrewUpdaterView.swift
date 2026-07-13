import SwiftUI

struct HomebrewUpdaterView: View {
    @StateObject private var service = HomebrewService()
    @State private var showLog = false

    var body: some View {
        FeaturePageShell(
            title: "Homebrew Updater",
            subtitle: "Keep your Homebrew packages up to date.",
            trailing: AnyView(
                RescanButton(
                    title: "Check Updates",
                    isScanning: service.isLoading || service.isUpgrading,
                    usesNativeToolbarStyle: true
                ) {
                    Task { await service.checkOutdated() }
                }
            )
        ) {
            VStack(spacing: 0) {
                if !service.brewExists() {
                    brewNotFoundView
                } else if service.isLoading {
                    loadingView
                } else if service.packages.isEmpty {
                    emptyView
                } else {
                    packageList
                }

                if let error = service.error, error != "brew_not_found" {
                    MacSweepErrorBanner(message: error) {
                        service.error = nil
                    }
                }

                if !service.packages.isEmpty && !service.isLoading {
                    Divider()
                    bottomBar
                }

                if service.isUpgrading || showLog && !service.upgradeLog.isEmpty {
                    Divider()
                    upgradeLogView
                }
            }
        }
        .task {
            if service.brewExists() {
                await service.checkOutdated()
            }
        }
    }

    // MARK: - Package List

    private var packageList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(service.packages.count) outdated")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    Task { await service.analyzeWithAI() }
                } label: {
                    Label(
                        service.isAnalyzingAI ? "Analyzing…" : "AI Analysis",
                        systemImage: "sparkles"
                    )
                }
                .glassButton()
                .controlSize(.small)
                .disabled(service.isAnalyzingAI || service.isUpgrading)
                .help("Use Claude AI to summarize changes and flag breaking updates")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            List {
                ForEach($service.packages) { $pkg in
                    PackageRow(package: $pkg)
                }
            }
            .listStyle(.inset)
            .macSweepListSurface()
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.5)
            Text("Checking for outdated packages…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("All packages are up to date")
                .font(.headline)
            Text("Your Homebrew packages are looking fresh 🍺")
                .foregroundStyle(.secondary)
            Button("Check Again") {
                Task { await service.checkOutdated() }
            }
            .glassButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var brewNotFoundView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Homebrew Not Found")
                .font(.headline)
            Text("Install Homebrew to manage packages from the command line.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("Install Homebrew", destination: URL(string: "https://brew.sh")!)
                .glassButton(prominent: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            let selectedCount = service.packages.filter(\.isSelected).count
            Text("\(selectedCount) of \(service.packages.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Select All") {
                for i in service.packages.indices { service.packages[i].isSelected = true }
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button("Upgrade Selected") {
                showLog = true
                Task { await service.upgradeSelected() }
            }
            .glassButton()
            .disabled(service.isUpgrading || service.packages.filter(\.isSelected).isEmpty)

            Button("Upgrade All") {
                showLog = true
                Task { await service.upgradeAll() }
            }
            .glassButton(prominent: true)
            .disabled(service.isUpgrading)
        }
        .padding()
    }

    // MARK: - Upgrade Log

    private var upgradeLogView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upgrade Log")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                if !service.isUpgrading {
                    Button { showLog = false } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            ScrollView {
                Text(service.upgradeLog)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .frame(height: 140)
            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .macSweepCard(radius: 12)
    }
}

// MARK: - Package Row

struct PackageRow: View {
    @Binding var package: BrewPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                // Checkbox
                SelectionCheckmark(isSelected: package.isSelected) {
                    package.isSelected.toggle()
                }

                // Brew icon
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                // Name + versions
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                        .font(.body)
                        .fontWeight(.medium)

                    HStack(spacing: 4) {
                        Text(package.currentVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(package.latestVersion)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                }

                Spacer()

                // AI Insight badges
                if let insight = package.aiInsight {
                    HStack(spacing: 6) {
                        if insight.hasBreakingChanges {
                            Label("Breaking", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.85), in: Capsule())
                        }

                        Text(insight.upgradeRecommendation)
                            .font(.caption2)
                            .foregroundStyle(insight.upgradeRecommendation == "Safe" ? .green : .orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                (insight.upgradeRecommendation == "Safe" ? Color.green : Color.orange).opacity(0.15),
                                in: Capsule()
                            )
                    }
                }
            }

            // AI insight detail (breaking changes warning)
            if let insight = package.aiInsight {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                        Text(insight.changesSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 36)

                    if insight.hasBreakingChanges, let detail = insight.breakingChangesDetail {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(.leading, 36)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 36)
                        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.leading, 36)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    HomebrewUpdaterView()
        .frame(width: 800, height: 600)
}
#endif
