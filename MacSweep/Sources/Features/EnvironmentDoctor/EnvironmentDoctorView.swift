import SwiftUI

struct EnvironmentDoctorView: View {
    private let service: EnvironmentDoctorService
    private let isSnapshot: Bool
    @State private var inventory: DoctorInventory
    @State private var selected = Set<String>()
    @State private var scanning = false
    @State private var hasChecked = false
    @State private var review = false
    @State private var administratorAcknowledged = false
    @State private var message: String?

    init(service: EnvironmentDoctorService? = nil, snapshotInventory: DoctorInventory? = nil) {
        var production = EnvironmentDoctorService()
        production.privilegedTrash = { try await PrivilegedRunner.repairDoctorFinding($0) }
        self.service = service ?? production
        self.isSnapshot = snapshotInventory != nil
        _inventory = State(initialValue: snapshotInventory ?? DoctorInventory())
        _hasChecked = State(initialValue: snapshotInventory != nil)
    }

    var body: some View {
        FeaturePageShell(
            title: "Environment Doctor", subtitle: "Inspect launch items, bin links, login PATH and Homebrew"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(
                        "Repairs move only selected files or links to Trash. "
                            + "Shell configuration is always suggest-only."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run Checks", systemImage: "stethoscope") { Task { await scan() } }
                        .disabled(scanning || isSnapshot)
                }
                if scanning { ProgressView("Checking your developer environment…") }
                if let message { MacSweepErrorBanner(message: message) { self.message = nil } }
                if !inventory.issues.isEmpty {
                    Text(inventory.issues.joined(separator: "\n")).foregroundStyle(.orange)
                        .font(.caption).textSelection(.enabled)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(DoctorCategory.allCases, id: \.rawValue) { category in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category.rawValue).font(.headline)
                                let findings = inventory.findings.filter { $0.category == category }
                                if findings.isEmpty {
                                    Text(
                                        scanning
                                            ? "Checking…"
                                            : hasChecked
                                                ? "No findings in the completed check; see any coverage issues above."
                                                : "Run Checks to inspect this category."
                                    )
                                    .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(findings) { finding in findingRow(finding) }
                            }
                        }
                    }
                }
                if selectedFindings.contains(where: \.requiresAdministrator) {
                    Toggle(
                        "I understand macOS will ask for administrator authorization before system repairs.",
                        isOn: $administratorAcknowledged)
                }
                HStack {
                    Text("\(selectedFindings.count) selected")
                    Spacer()
                    Button("Review Repairs…") { review = true }
                        .disabled(
                            selectedFindings.isEmpty || scanning || isSnapshot
                                || selectedFindings.contains(where: \.requiresAdministrator)
                                    && !administratorAcknowledged
                        )
                }
            }
            .padding()
        }
        .cleanupReview(
            isPresented: $review, items: selectedFindings.compactMap(\.preview), disposition: .trash,
            note: "PATH and Homebrew suggestions are never applied. Loaded launch jobs are not stopped. "
                + "System repairs require administrator authorization. Privileged Trash items have a unique suffix; "
                + "restoring them to their original system location requires administrator access.", onConfirm: repair)
    }

    private var selectedFindings: [DoctorFinding] {
        inventory.findings.filter { selected.contains($0.id) && $0.canRepair }
    }

    private func findingRow(_ finding: DoctorFinding) -> some View {
        HStack(alignment: .top) {
            Toggle(
                "Select repair",
                isOn: Binding(
                    get: { selected.contains(finding.id) },
                    set: { if $0 { selected.insert(finding.id) } else { selected.remove(finding.id) } })
            )
            .labelsHidden().disabled(!finding.canRepair || scanning || isSnapshot)
            VStack(alignment: .leading, spacing: 5) {
                if let path = finding.path { Text(path.path).font(.caption.monospaced()).textSelection(.enabled) }
                Label("Warning", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Text(finding.evidence).textSelection(.enabled)
                Text(finding.remediation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if finding.requiresAdministrator { Label("Administrator required", systemImage: "lock.shield") }
                if let reason = finding.retentionReason { Text(reason).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacSweepTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }

    private func scan() async {
        scanning = true
        defer { scanning = false }
        selected = []
        administratorAcknowledged = false
        inventory = await service.scan()
        hasChecked = true
    }

    private func repair() async -> CleanupResult? {
        let result = await service.repair(
            selectedFindings, confirmed: true,
            administratorAcknowledged: administratorAcknowledged)
        inventory = await service.scan()
        hasChecked = true
        selected = []
        message = result.failureSummaryMessage
        return result
    }
}
