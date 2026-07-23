import Darwin
import Foundation
import Testing
@testable import MacSweepCore

struct RunningProcessSortOrderTests {
    @Test func pickerContractPreservesLabelsAndOrder() {
        #expect(RunningProcessSortOrder.allCases == [.memory, .cpu, .name])
        #expect(RunningProcessSortOrder.allCases.map(\.rawValue) == ["Memory", "CPU", "Name"])
    }

    @Test func sortsMemoryAndCPUDescending() {
        let lowMemoryHighCPU = process(
            pid: 101,
            name: "CPU Worker",
            memoryMB: 128,
            cpuPercent: 80
        )
        let balanced = process(
            pid: 102,
            name: "Balanced",
            memoryMB: 512,
            cpuPercent: 40
        )
        let highMemoryLowCPU = process(
            pid: 103,
            name: "Memory Worker",
            memoryMB: 2_048,
            cpuPercent: 5
        )
        let processes = [balanced, lowMemoryHighCPU, highMemoryLowCPU]

        #expect(processes.sorted(using: .memory).map(\.pid) == [103, 102, 101])
        #expect(processes.sorted(using: .cpu).map(\.pid) == [101, 102, 103])
    }

    @Test func sortsNamesUsingLocalizedAscendingComparison() {
        let processes = [
            process(pid: 201, name: "Zulu"),
            process(pid: 202, name: "Alpha"),
            process(pid: 203, name: "Echo")
        ]

        #expect(processes.sorted(using: .name).map(\.name) == ["Alpha", "Echo", "Zulu"])
    }

    @Test func everySortModeAcceptsEmptyInput() {
        let processes: [RunningProcess] = []

        for order in RunningProcessSortOrder.allCases {
            #expect(processes.sorted(using: order).isEmpty)
        }
    }

    private func process(
        pid: pid_t,
        name: String,
        memoryMB: Double = 0,
        cpuPercent: Double = 0
    ) -> RunningProcess {
        RunningProcess(
            pid: pid,
            name: name,
            bundleID: nil,
            icon: nil,
            memoryMB: memoryMB,
            cpuPercent: cpuPercent,
            isActive: false
        )
    }
}
