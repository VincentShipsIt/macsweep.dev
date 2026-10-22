import Foundation

extension AppState {
    private func applyScanResults(_ items: [CleanupItem], modules: [String]?) {
        scanResults = items.sorted { $0.size > $1.size }

        let summary = SmartCareAnalyzer().summarize(items: scanResults, diskUsage: diskUsage)
        smartCareSummary = summary

        if modules == nil || Set(modules ?? []).isSuperset(of: SmartCareDefaults.moduleIDs) {
            selectedItems = summary.recommendedCleanupItemIDs
        } else {
            selectedItems = Set(scanResults.map(\.id))
        }
    }

    func startScan(scope: ScanScope) async {
        // Serialize concurrent scan requests instead of dropping them. The previous
        // early `return` discarded this caller's modules/targets and let them see an
        // unrelated in-flight scan's results (e.g. an assistant plan showing a
        // background quick-scan's findings). Wait for any in-flight scan — and any a
        // peer waiter starts ahead of us — to finish, THEN run the requested scan.
        while let activeScanTask {
            guard !Task.isCancelled else { return }
            await activeScanTask.value
        }
        guard !Task.isCancelled else { return }
        let scanID = UUID()
        activeScanID = scanID

        let task = Task { @MainActor in
            await self.performScan(
                scope: scope
            )

            if self.activeScanID == scanID {
                self.activeScanTask = nil
                self.activeScanID = nil
            }
        }

        activeScanTask = task
        await task.value
    }

    private func performScan(scope: ScanScope) async {
        lastScanScope = scope
        isScanning = true
        scanProgress = 0
        currentScanModule = "Preparing scan"
        scanResults = []
        selectedItems = []
        smartCareSummary = nil
        scanFailures = []
        lastError = nil

        defer {
            isScanning = false
            currentScanModule = nil
        }

        let progressHandler: ScanProgressHandler = { update in
            await MainActor.run {
                self.scanProgress = update.fractionCompleted

                if let moduleName = update.moduleName {
                    self.currentScanModule = "Completed \(moduleName)"
                } else if update.totalModules > 0 {
                    self.currentScanModule = "Scanning \(update.totalModules) modules"
                } else {
                    self.currentScanModule = "Preparing scan"
                }
            }
        }

        do {
            async let primaryResult = scanEngine.scanWithDiagnostics(
                modules: scope.modules,
                progress: progressHandler
            )
            async let watchlistResult = assistantResults(scope.assistantTargets)
            let result = await primaryResult
            currentScanModule =
                scope.assistantTargets.isEmpty
                ? "Finalizing results"
                : "Checking assistant watchlist"
            scanProgress = max(scanProgress, 0.95)
            let (persistentItems, assistantFailures) = await watchlistResult
            try Task.checkCancellation()
            let combined = deduplicated(items: result.items + persistentItems)
            scanFailures = (result.failures + assistantFailures).sorted {
                $0.moduleName.localizedStandardCompare($1.moduleName) == .orderedAscending
            }
            applyScanResults(combined, modules: scope.modules)
            scanProgress = 1
        } catch is CancellationError {
            // User-initiated stop — not an error worth a banner.
        } catch {
            // Surface to the UI instead of swallowing into a console log.
            lastError = "Scan failed: \(error.localizedDescription)"
        }
    }

    private func deduplicated(items: [CleanupItem]) -> [CleanupItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = "\(item.module)|\(item.path.path)"
            return seen.insert(key).inserted
        }
    }
    private func assistantResults(_ targets: [AssistantScanTarget]) async -> ([CleanupItem], [ModuleScanFailure]) {
        do {
            return (try await scanEngine.scanAssistantTargets(targets), [])
        } catch let partial as PartialModuleScanError {
            return (
                partial.items,
                [
                    ModuleScanFailure(
                        moduleID: AssistantWatchlistModule.moduleID,
                        moduleName: "Assistant Watchlists", message: partial.localizedDescription)
                ]
            )
        } catch {
            return (
                [],
                [
                    ModuleScanFailure(
                        moduleID: AssistantWatchlistModule.moduleID,
                        moduleName: "Assistant Watchlists", message: error.localizedDescription)
                ]
            )
        }
    }
}
