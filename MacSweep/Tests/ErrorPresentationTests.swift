import Testing
import Foundation
import SwiftUI
@testable import MacSweepCore

// Coverage for the shared error-presentation helpers: the Optional→Bool binding
// that backs `.errorAlert`, and the generic per-item failure summary that
// replaced the "blocked by safety checks" mislabeling.

struct ErrorPresentationTests {

    // MARK: - Binding.isPresent()

    @Test func isPresentIsTrueWhileMessageIsSet() {
        var message: String? = "boom"
        let binding = Binding(get: { message }, set: { message = $0 })

        #expect(binding.isPresent().wrappedValue == true)
    }

    @Test func isPresentIsFalseWhenMessageIsNil() {
        var message: String?
        let binding = Binding(get: { message }, set: { message = $0 })

        #expect(binding.isPresent().wrappedValue == false)
    }

    @Test func settingFalseClearsTheMessage() {
        var message: String? = "boom"
        let binding = Binding(get: { message }, set: { message = $0 })

        binding.isPresent().wrappedValue = false

        #expect(message == nil)
    }

    @Test func settingTrueLeavesTheMessageUntouched() {
        var message: String? = "boom"
        let binding = Binding(get: { message }, set: { message = $0 })

        binding.isPresent().wrappedValue = true

        #expect(message == "boom")
    }

    // MARK: - failureSummaryMessage

    @Test func noErrorsProducesNoSummary() {
        let result = CleanupResult(itemsProcessed: 3, bytesFreed: 1024)

        #expect(result.failureSummaryMessage == nil)
    }

    @Test func singleErrorUsesSingularWordingAndItsOwnMessage() {
        let result = CleanupResult(
            itemsProcessed: 0,
            bytesFreed: 0,
            errors: [CleanupError(path: URL(fileURLWithPath: "/tmp/a"), message: "Operation not permitted")]
        )

        #expect(result.failureSummaryMessage == "1 item couldn't be removed: Operation not permitted")
    }

    @Test func multipleErrorsUsePluralWordingAndTheFirstMessage() {
        let errors = [
            CleanupError(path: URL(fileURLWithPath: "/tmp/a"), message: "Blocked by safety checks"),
            CleanupError(path: URL(fileURLWithPath: "/tmp/b"), message: "File is in use"),
        ]

        #expect(errors.failureSummaryMessage == "2 items couldn't be removed: Blocked by safety checks")
    }

    @Test func summaryNeverInventsASafetyBlockLabel() throws {
        // A plain deletion failure must surface its own reason, not a safety claim.
        let result = CleanupResult(
            itemsProcessed: 0,
            bytesFreed: 0,
            errors: [CleanupError(path: URL(fileURLWithPath: "/tmp/a"), message: "Permission denied")]
        )

        let summary = try #require(result.failureSummaryMessage)
        #expect(!summary.localizedCaseInsensitiveContains("safety"))
    }
}
