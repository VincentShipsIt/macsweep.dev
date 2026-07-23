import Testing
@testable import MacSweepCore

@Suite("Full Disk Access recovery copy")
struct FullDiskAccessScopeTests {
    @Test("Scoped warnings name the protected area and explain partial results")
    func scopedWarningsAreSpecific() {
        #expect(FullDiskAccessScope.mail.title.contains("Apple Mail"))
        #expect(FullDiskAccessScope.mail.detail.contains("skipped"))
        #expect(FullDiskAccessScope.trash.title.contains("Trash"))
        #expect(FullDiskAccessScope.trash.detail.contains("cannot be verified"))
        #expect(FullDiskAccessScope.safari.title.contains("Safari"))
        #expect(FullDiskAccessScope.safari.detail.contains("other supported browsers"))
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
}
