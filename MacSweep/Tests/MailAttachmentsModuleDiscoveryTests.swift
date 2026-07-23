import Foundation
import Testing
@testable import MacSweepCore

@Suite("Mail attachment discovery")
struct MailAttachmentsModuleDiscoveryTests {
    @Test func discoversModernSparkDesktopAttachments() async throws {
        let temporaryDirectory = try TempTestDirectory(prefix: "SparkDesktopAttachments")
        let attachmentDirectory = temporaryDirectory.url.appending(
            path: "Library/Application Support/Spark Desktop/core-data/attachments"
        )
        try FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )
        let attachment = attachmentDirectory.appending(path: "invoice.pdf")
        try Data(repeating: 0xA5, count: 2_048).write(to: attachment)

        var module = MailAttachmentsModule()
        module.homeDirectory = temporaryDirectory.url
        module.threshold = 1

        let results = try await module.scan()

        #expect(
            results.map { $0.path.resolvingSymlinksInPath() }
                == [attachment.resolvingSymlinksInPath()]
        )
        #expect(results.first?.moduleName == "Spark - Documents")
    }

    @Test func modernSparkDiscoveryDoesNotScanItsDatabasesOrGenericCaches() {
        let home = URL(fileURLWithPath: "/Users/example")
        let locations = MailAttachmentsModule.attachmentLocations(homeDirectory: home)
            .map(\.path.path)

        #expect(locations.contains(
            "/Users/example/Library/Application Support/Spark Desktop/core-data/attachments"
        ))
        #expect(!locations.contains(
            "/Users/example/Library/Application Support/Spark Desktop"
        ))
        #expect(!locations.contains(
            "/Users/example/Library/Application Support/Spark Desktop/Cache"
        ))
    }
}
