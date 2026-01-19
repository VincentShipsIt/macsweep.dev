import SwiftUI
import AppKit

/// Optimization view with process list and memory management
struct OptimizationView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processMonitor = ProcessMonitor()
    @StateObject private var systemMonitor = SystemMonitor()
    @State private var selectedProcesses: Set<pid_t> = []
    @State private var showingQuitConfirmation = false
    @State private var isFreezingRAM = false
    @State private var sortOrder: ProcessSortOrder = .memory

    enum ProcessSortOrder: String, CaseIterable {
        case memory = "Memory"
        case cpu = "CPU"
        case name = "Name"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // System stats row
            systemStatsRow
                .padding()

            Divider()

            // Process list
            processList

            // Footer with actions
            if !selectedProcesses.isEmpty {
                Divider()
                footer
            }
        }
        .task {
            await processMonitor.startMonitoring()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Optimization")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Manage running processes and free up memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Free up RAM button
            Button {
                Task {
                    await freeUpRAM()
                }
            } label: {
                Label("Free Up RAM", systemImage: "memorychip")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isFreezingRAM)

            // Refresh
            Button {
                Task {
                    await processMonitor.refresh()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding()
    }

    // MARK: - System Stats Row

    private var systemStatsRow: some View {
        HStack(spacing: 24) {
            // Memory pressure
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                        .frame(width: 80, height: 80)

                    Circle()
                        .trim(from: 0, to: systemMonitor.memoryUsage.usedPercentage)
                        .stroke(memoryColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))

                    Text("\(Int(systemMonitor.memoryUsage.usedPercentage * 100))%")
                        .font(.headline)
                }

                Text("Memory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Memory details
            VStack(alignment: .leading, spacing: 4) {
                MemoryStatRow(label: "Used", value: systemMonitor.memoryUsage.formattedUsed, color: .blue)
                MemoryStatRow(label: "Wired", value: systemMonitor.memoryUsage.formattedWired, color: .red)
                MemoryStatRow(label: "Compressed", value: systemMonitor.memoryUsage.formattedCompressed, color: .orange)
                MemoryStatRow(label: "Free", value: systemMonitor.memoryUsage.formattedFree, color: .green)
            }

            Divider()
                .frame(height: 80)

            // CPU
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                        .frame(width: 80, height: 80)

                    Circle()
                        .trim(from: 0, to: min(1.0, systemMonitor.cpuUsage.total / 100))
                        .stroke(cpuColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .frame(width: 80, height: 80)
                        .rotationEffect(.degrees(-90))

                    Text("\(Int(systemMonitor.cpuUsage.total))%")
                        .font(.headline)
                }

                Text("CPU")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // CPU details
            VStack(alignment: .leading, spacing: 4) {
                CPUStatRow(label: "User", value: systemMonitor.cpuUsage.user, color: .blue)
                CPUStatRow(label: "System", value: systemMonitor.cpuUsage.system, color: .red)
                CPUStatRow(label: "Idle", value: systemMonitor.cpuUsage.idle, color: .green)
            }

            Spacer()

            // Process count
            VStack(spacing: 4) {
                Text("\(processMonitor.processes.count)")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Processes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Process List

    private var processList: some View {
        VStack(spacing: 0) {
            // Sort controls
            HStack {
                Text("Running Processes")
                    .font(.headline)

                Spacer()

                Picker("Sort by", selection: $sortOrder) {
                    ForEach(ProcessSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Process table
            List(selection: $selectedProcesses) {
                ForEach(sortedProcesses) { process in
                    ProcessRow(process: process, isSelected: selectedProcesses.contains(process.pid))
                        .tag(process.pid)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(selectedProcesses.count) processes selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Deselect All") {
                selectedProcesses.removeAll()
            }
            .buttonStyle(.bordered)

            Button {
                showingQuitConfirmation = true
            } label: {
                Label("Quit Selected", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding()
        .confirmationDialog(
            "Quit \(selectedProcesses.count) Processes?",
            isPresented: $showingQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Quit", role: .destructive) {
                quitSelectedProcesses()
            }
            Button("Force Quit", role: .destructive) {
                forceQuitSelectedProcesses()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quitting processes may cause data loss if they have unsaved changes.")
        }
    }

    // MARK: - Actions

    private func freeUpRAM() async {
        isFreezingRAM = true

        // Run purge command (requires sudo, may not work without privileges)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/purge")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Purge failed: \(error)")
        }

        // Refresh after a moment
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await systemMonitor.refresh()

        isFreezingRAM = false
    }

    private func quitSelectedProcesses() {
        for pid in selectedProcesses {
            if let process = processMonitor.processes.first(where: { $0.pid == pid }) {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.terminate()
                }
            }
        }
        selectedProcesses.removeAll()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await processMonitor.refresh()
        }
    }

    private func forceQuitSelectedProcesses() {
        for pid in selectedProcesses {
            kill(pid, SIGKILL)
        }
        selectedProcesses.removeAll()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await processMonitor.refresh()
        }
    }

    // MARK: - Computed

    private var sortedProcesses: [ProcessInfo] {
        switch sortOrder {
        case .memory:
            return processMonitor.processes.sorted { $0.memoryMB > $1.memoryMB }
        case .cpu:
            return processMonitor.processes.sorted { $0.cpuPercent > $1.cpuPercent }
        case .name:
            return processMonitor.processes.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    private var memoryColor: Color {
        let usage = systemMonitor.memoryUsage.usedPercentage
        if usage > 0.9 { return .red }
        if usage > 0.7 { return .orange }
        return .green
    }

    private var cpuColor: Color {
        let usage = systemMonitor.cpuUsage.total
        if usage > 80 { return .red }
        if usage > 50 { return .orange }
        return .green
    }
}

// ProcessMonitor and ProcessInfo are defined in Core/Monitoring/ProcessMonitor.swift

// MARK: - Process Row

struct ProcessRow: View {
    let process: ProcessInfo
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)

            // App icon
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app")
                    .frame(width: 24, height: 24)
            }

            // Name
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(process.name)
                        .lineLimit(1)

                    if process.isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                    }
                }

                if let bundleID = process.bundleID {
                    Text(bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Memory
            VStack(alignment: .trailing, spacing: 2) {
                Text(process.formattedMemory)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(memoryColor)

                Text("Memory")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 70)

            // CPU
            VStack(alignment: .trailing, spacing: 2) {
                Text(process.formattedCPU)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(cpuColor)

                Text("CPU")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 50)
        }
        .padding(.vertical, 4)
    }

    private var memoryColor: Color {
        if process.memoryMB > 1024 { return .red }
        if process.memoryMB > 512 { return .orange }
        return .primary
    }

    private var cpuColor: Color {
        if process.cpuPercent > 50 { return .red }
        if process.cpuPercent > 20 { return .orange }
        return .primary
    }
}

// MARK: - Supporting Views

struct MemoryStatRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

struct CPUStatRow: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(String(format: "%.1f%%", value))
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    OptimizationView()
        .environmentObject(AppState())
        .frame(width: 800, height: 600)
}
