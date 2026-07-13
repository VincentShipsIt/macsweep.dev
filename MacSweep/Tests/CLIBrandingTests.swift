import Foundation
import Testing
@testable import MacSweepCLIKit

struct CLIBrandingTests {
    @Test func rendersVersionWithProductBrand() {
        let output = CLIVersionOutput(
            metadata: CLICommandMetadata(command: "version", timestamp: Date(), executedModules: []),
            version: "1.2.3"
        )

        #expect(CLIExecutor.renderText(output) == "macsweep.dev 1.2.3")
    }
}
