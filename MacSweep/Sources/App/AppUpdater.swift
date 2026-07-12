import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle for the lifetime of the app and exposes its standard update UI.
///
/// Release builds receive `SUPublicEDKey` from the protected release environment.
/// Local and CI builds intentionally leave it empty, so they can build without a
/// production signing key and never contact the production appcast by accident.
@MainActor
final class AppUpdater {
    let updaterController: SPUStandardUpdaterController
    let isConfigured: Bool

    var updater: SPUUpdater { updaterController.updater }

    init(bundle: Bundle = .main) {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isConfigured = Self.hasValue(feedURL) && Self.hasValue(publicKey)

        if isConfigured {
            updaterController.startUpdater()
        }
    }

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(")
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }
}

/// SwiftUI command content for the standard app-menu update action.
struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    private let isConfigured: Bool

    init(appUpdater: AppUpdater) {
        updater = appUpdater.updater
        isConfigured = appUpdater.isConfigured
        _viewModel = StateObject(
            wrappedValue: CheckForUpdatesViewModel(updater: appUpdater.updater)
        )
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!isConfigured || !viewModel.canCheckForUpdates)
    }
}
