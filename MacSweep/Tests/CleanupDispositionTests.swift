import Testing
@testable import MacSweepCore

@Suite("Cleanup disposition")
struct CleanupDispositionTests {
    @Test func preservesTrashConfirmationContract() {
        #expect(CleanupDisposition.trash.title == "Move to Trash")
        #expect(
            CleanupDisposition.trash.detail
                == "Selected files move to Trash and can be restored until Trash is emptied."
        )
        #expect(CleanupDisposition.trash.icon == "trash")
    }

    @Test func preservesPermanentDeletionContract() {
        #expect(CleanupDisposition.permanent.title == "Delete Permanently")
        #expect(
            CleanupDisposition.permanent.detail
                == "Selected files are deleted permanently and cannot be restored from Trash."
        )
        #expect(CleanupDisposition.permanent.icon == "trash.slash")
    }

    @Test func preservesLocalCloudCopyContract() {
        #expect(CleanupDisposition.localCloudCopy.title == "Remove Local Copies")
        #expect(
            CleanupDisposition.localCloudCopy.detail
                == "Downloaded local copies are evicted; the cloud originals remain available. "
                + "Provider caches may be deleted permanently."
        )
        #expect(CleanupDisposition.localCloudCopy.icon == "icloud.and.arrow.up")
    }

    @Test func preservesMixedCleanupContract() {
        #expect(CleanupDisposition.mixed.title == "Run Cleanup")
        #expect(
            CleanupDisposition.mixed.detail
                == "Each module uses its declared action. Some items move to Trash; "
                + "tool-managed caches or Trash contents may be removed permanently."
        )
        #expect(CleanupDisposition.mixed.icon == "checkmark.shield")
    }

    @Test func preservesToolNativeDetail() {
        let disposition = CleanupDisposition.toolNative("Runs the tool's own cleanup command.")

        #expect(disposition.title == "Run Tool Cleanup")
        #expect(disposition.detail == "Runs the tool's own cleanup command.")
        #expect(disposition.icon == "terminal")
    }
}
