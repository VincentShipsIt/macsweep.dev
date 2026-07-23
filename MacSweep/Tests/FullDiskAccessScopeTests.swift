import Testing
@testable import MacSweepCore

@Suite("Full Disk Access recovery copy")
struct FullDiskAccessScopeTests {
    @Test("Scoped warnings name the protected area and blocked state")
    func scopedWarningsAreSpecific() {
        #expect(FullDiskAccessScope.mail.title.contains("Apple Mail"))
        #expect(FullDiskAccessScope.mail.detail.contains("stay disabled"))
        #expect(FullDiskAccessScope.trash.title.contains("Trash"))
        #expect(FullDiskAccessScope.trash.detail.contains("cannot be verified"))
        #expect(FullDiskAccessScope.safari.title.contains("Safari"))
        #expect(FullDiskAccessScope.safari.detail.contains("without returning partial results"))
        #expect(FullDiskAccessScope.systemData.title.contains("system data"))
        #expect(FullDiskAccessScope.systemData.detail.contains("incomplete"))
    }

    @Test("Smart Care warning names every protected source")
    func smartCareWarningNamesProtectedSources() {
        let detail = FullDiskAccessScope.smartCare.detail
        #expect(detail.contains("Apple Mail"))
        #expect(detail.contains("Safari"))
        #expect(detail.contains("system data"))
    }

    @Test("Blocked actions explain how to recover")
    func blockedActionsExplainRecovery() {
        for scope in [
            FullDiskAccessScope.smartCare,
            .systemData,
            .mail,
            .trash,
            .safari
        ] {
            #expect(scope.actionBlockedMessage.contains("Grant Full Disk Access"))
        }
    }
}
