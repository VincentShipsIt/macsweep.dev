import Combine
import Foundation

/// Which stage of the scan loop a feature page is showing. Feature pages with
/// more than a plain landing/results swap compute this and drive their motion
/// from it so every state change is represented explicitly.
enum ScanPhase: Equatable {
    case landing
    case scanning
    case empty
    case results
}

/// Shared scan/selection/cleanup state machine for the feature views.
///
/// Roughly a dozen feature views each re-declared the same `@State` cluster —
/// `isScanning`, a `[CleanupItem]` result list, a `Set<UUID>` selection, a
/// `showingConfirmation` flag and an `errorMessage` — wired to a near-identical
/// scan closure and a copy-pasted cleanup epilogue. This owns that machine once
/// so a view holds a single `@StateObject` and supplies only the module scan and
/// the human-readable failure strings.
///
/// It follows `AppState`'s `ObservableObject`/`@Published` idiom (not `@Observable`)
/// so `$model.selectedItems` / `$model.showingConfirmation` bindings work in the
/// views with no extra `@Bindable` dance, and so the snapshot-seeding initializers
/// can inject state through `StateObject(wrappedValue:)`.
@MainActor
final class ScanFeatureModel: ObservableObject {
    typealias CleanupOperation = ([CleanupItem]) async throws -> CleanupResult

    /// True while a scan is running. Rescan buttons disable on this.
    @Published var isScanning = false

    /// True once at least one scan has finished (used by the views that show a
    /// distinct "scanned, nothing found" state versus the initial landing).
    @Published var hasScanned = false

    /// The current scan results.
    @Published var items: [CleanupItem] = []

    /// The user's selection within `items`.
    @Published var selectedItems: Set<CleanupItem.ID> = []

    /// Drives the pre-deletion confirmation dialog.
    @Published var showingConfirmation = false

    /// Last scan or cleanup failure surfaced to the UI; `nil` when clear.
    @Published var errorMessage: String?

    /// The in-flight scan. A rescan cancels this before starting, and a view can
    /// cancel it on disappear, so a superseded or abandoned scan never clobbers
    /// the state that replaced it.
    private var scanTask: Task<Void, Never>?

    /// Bumped on every `scan(_:)`. The deferred flag reset and the result
    /// assignment both check it, so a late-finishing prior scan defers to the
    /// newest one instead of overwriting `isScanning`/`items`.
    private var scanGeneration = 0

    /// Optional test seam for cleanup result reconciliation. Production callers
    /// keep using `ScanEngine`; focused tests can return deterministic results
    /// without deleting or moving files on the host.
    private let cleanupOperation: CleanupOperation?

    /// Production initializer — empty until the first scan.
    init() {
        cleanupOperation = nil
    }

    /// Seeds result state directly, for the snapshot-rendering harness and Xcode
    /// previews that render populated, successful-empty, or error layouts without
    /// a live scan.
    init(
        items: [CleanupItem],
        selectedItems: Set<CleanupItem.ID> = [],
        isScanning: Bool = false,
        hasScanned: Bool = false,
        errorMessage: String? = nil
    ) {
        cleanupOperation = nil
        self.items = items
        self.selectedItems = selectedItems
        self.isScanning = isScanning
        self.hasScanned = hasScanned
        self.errorMessage = errorMessage
    }

    /// Test initializer for deterministic cleanup outcomes. Scan and selection
    /// behavior remains identical to the production initializer.
    init(cleanupOperation: @escaping CleanupOperation) {
        self.cleanupOperation = cleanupOperation
    }

    /// The shared landing/loading/result state projected for feature-page
    /// transitions. Views with a distinct scanning arm can derive their own
    /// phase, while the standard landing view renders `isScanning` internally.
    var scanPhase: ScanPhase {
        if !items.isEmpty { return .results }
        if hasScanned && !isScanning && errorMessage == nil { return .empty }
        return .landing
    }

    // MARK: - Scanning

    /// Runs `body` as the active scan.
    ///
    /// Cancels any in-flight scan first, clears the result state, flips
    /// `isScanning` (reset in a `defer`), then routes the outcome: success assigns
    /// `items` (optionally selecting them all), a thrown error is mapped through
    /// `onError` into `errorMessage` (pass `nil` to swallow, matching the views
    /// that used `try?`), and cancellation is ignored so a superseding rescan owns
    /// the state.
    ///
    /// - Parameters:
    ///   - selectAllOnCompletion: Select every scanned item on success. Views that
    ///     start with nothing selected pass `false`.
    ///   - onError: Formats a thrown error into the banner string, or `nil` to
    ///     leave `errorMessage` clear on failure.
    ///   - body: The module scan; its returned items become `items`.
    func scan(
        selectAllOnCompletion: Bool = true,
        onError: ((Error) -> String)? = nil,
        _ body: @escaping () async throws -> [CleanupItem]
    ) async {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration

        let task = Task { @MainActor in
            isScanning = true
            items = []
            selectedItems = []
            errorMessage = nil

            defer {
                // Only the current scan owns the shared flags; a superseded scan
                // that finishes late must not toggle them back on the newer one.
                if generation == scanGeneration {
                    isScanning = false
                    hasScanned = true
                }
            }

            do {
                let scanned = try await body()
                // A rescan started while `body` ran supersedes this result.
                try Task.checkCancellation()
                guard generation == scanGeneration else { return }
                items = scanned
                if selectAllOnCompletion {
                    selectedItems = Set(scanned.map(\.id))
                }
            } catch is CancellationError {
                // Superseded or cancelled — leave the state to whoever replaced us.
            } catch {
                guard generation == scanGeneration else { return }
                if let onError {
                    errorMessage = onError(error)
                }
            }
        }

        scanTask = task
        await task.value
    }

    /// Token identifying the active scan generation. A view that keeps derived
    /// state (e.g. review groups) alongside `items` reads this at the start of
    /// its scan body and commits that state only while `isCurrent(_:)` still
    /// holds, so a late-finishing scan can't overwrite newer derived state —
    /// mirroring the guard `scan(_:)` already applies to `items`.
    var activeScanToken: Int { scanGeneration }

    /// Whether `token` (from `activeScanToken`) still identifies the newest scan.
    func isCurrent(_ token: Int) -> Bool { token == scanGeneration }

    /// Cancels the in-flight scan, if any. Safe to call when none is running.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Selection

    /// Selects every id in `list` (the view's filtered/sorted projection), the
    /// shared form of the copy-pasted `selectedItems = Set(list.map(\.id))` idiom.
    func selectAll(_ list: [CleanupItem]) {
        selectedItems = Set(list.map(\.id))
    }

    func deselectAll() {
        selectedItems.removeAll()
    }

    // MARK: - Cleanup

    /// Routes `itemsToClean` through the full `ScanEngine` safety pipeline, then
    /// prunes the successfully-removed items from `items`/`selectedItems` and
    /// surfaces any per-item failure summary.
    ///
    /// This is the shared form of the epilogue the deletion-bearing views copied:
    /// route through the engine (so per-item `SafetyChecker` + the aggregate
    /// `DeletionGuard` cap both apply); on a thrown failure (e.g. the cap) nothing
    /// is removed and `failureMessage(error)` is shown; otherwise drop the items
    /// that actually left disk while keeping any the engine blocked (their path
    /// comes back in `result.errors`), and show `result.failureSummaryMessage`.
    ///
    /// - Returns: The engine result, or `nil` if the whole operation threw.
    @discardableResult
    func clean(
        _ itemsToClean: [CleanupItem],
        failureMessage: (Error) -> String
    ) async -> CleanupResult? {
        let result: CleanupResult
        do {
            if let cleanupOperation {
                result = try await cleanupOperation(itemsToClean)
            } else {
                let engine = ScanEngine()
                result = try await engine.clean(
                    items: itemsToClean,
                    dryRun: false,
                    confirmedLargeDeletion: true
                )
            }
        } catch {
            errorMessage = failureMessage(error)
            return nil
        }

        let submittedIDs = Set(itemsToClean.map(\.id))
        let failedPaths = Set(result.errors.map(\.path))
        items.removeAll { submittedIDs.contains($0.id) && !failedPaths.contains($0.path) }
        selectedItems = selectedItems.filter { id in items.contains(where: { $0.id == id }) }
        errorMessage = result.failureSummaryMessage
        return result
    }
}
