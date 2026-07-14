import SwiftUI

struct MaintenanceView: View {
    @State private var runningTaskId: String?
    @State private var lastResult: MaintenanceResult?
    @State private var showingResult = false
    @State private var autoHideTask: Task<Void, Never>?

    var body: some View {
        FeaturePageShell(
            title: "Maintenance",
            subtitle: "Run upkeep tasks to keep your Mac healthy."
        ) {
            ScrollView {
                VStack(spacing: 24) {
                    if showingResult, let result = lastResult {
                        resultBanner(result)
                            .padding(.horizontal, 40)
                    }

                    VStack(spacing: 12) {
                        ForEach(MaintenanceTask.visibleTasks) { task in
                            MaintenanceTaskRow(
                                task: task,
                                isRunning: runningTaskId == task.id,
                                isDisabled: runningTaskId != nil
                            ) {
                                await runTask(task)
                            }
                        }

                        if hiddenTaskCount > 0 {
                            Label(hiddenTasksMessage, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 40)

                    Spacer(minLength: 40)
                }
                .padding(.top, 24)
            }
        }
        .onDisappear {
            autoHideTask?.cancel()
        }
    }

    private var hiddenTaskCount: Int {
        MaintenanceTask.allTasks.count - MaintenanceTask.visibleTasks.count
    }

    private var hiddenTasksMessage: String {
        "\(hiddenTaskCount) unsupported task\(hiddenTaskCount == 1 ? " is" : "s are") hidden "
            + "because the required macOS tools are unavailable."
    }

    private func resultBanner(_ result: MaintenanceResult) -> some View {
        HStack {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.success ? .green : .red)

            Text(result.message)
                .font(.caption)

            Spacer()

            Button {
                showingResult = false
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            result.success ? Color.green.opacity(0.1) : Color.red.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func runTask(_ task: MaintenanceTask) async {
        guard runningTaskId == nil else { return }
        runningTaskId = task.id
        showingResult = false

        do {
            lastResult = try await task.action()
        } catch {
            lastResult = MaintenanceResult(success: false, message: error.localizedDescription)
        }

        runningTaskId = nil
        showingResult = true

        // Cancel the prior timeout so it cannot dismiss a newer task's result.
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                showingResult = false
            }
        }
    }
}

struct MaintenanceTaskRow: View {
    let task: MaintenanceTask
    let isRunning: Bool
    let isDisabled: Bool
    let action: () async -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: task.icon)
                .font(.title2)
                .frame(width: 40)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.headline)

                Text(task.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if task.requiresAdmin {
                    Label("Requires administrator approval", systemImage: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(task.requiresAdmin ? "Run as Admin" : "Run") {
                    Task {
                        await action()
                    }
                }
                .glassButton()
                .disabled(isDisabled)
                .help(
                    task.requiresAdmin
                        ? "Shows the macOS administrator authorization prompt."
                        : "Run this maintenance task."
                )
            }
        }
        .padding()
        .macSweepCard(radius: 12)
    }
}
