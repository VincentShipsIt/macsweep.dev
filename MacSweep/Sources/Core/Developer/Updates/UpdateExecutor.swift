import Foundation

struct UpdateAcknowledgements: Sendable {
    var administrator = false
    var appStoreSignedIn = false
}

struct UpdateExecutor: Sendable {
    var scanner = UpdateScanner()
    var administratorUpdate: MasAdministratorUpdate?
    var streamingRunner: UpdateStreamingRunner = { command, output in
        try await ProcessRunner.runStreaming(
            executable: command.executable, arguments: command.arguments,
            currentDirectory: URL(fileURLWithPath: "/"), timeout: 600, onOutput: output)
    }

    func upgrade(
        _ selected: [PackageUpdate], acknowledgements: UpdateAcknowledgements = .init(),
        onOutput: @escaping ProcessOutputHandler
    ) async -> [UpdateOutcome] {
        if selected.contains(where: \.requiresAdministrator),
            !acknowledgements.administrator || !acknowledgements.appStoreSignedIn {
            return selected.map {
                .init(
                    update: $0, succeeded: false,
                    message: "Administrator authorization and App Store sign-in must be acknowledged before starting.")
            }
        }
        var sources = Set<UpdateSource>()
        let current: UpdateInventory
        do {
            current = try await scanner.scan(sources: selected.map(\.source).filter { sources.insert($0).inserted })
        } catch { return selected.map { .init(update: $0, succeeded: false, message: error.localizedDescription) } }
        var outcomes: [UpdateOutcome] = []
        var seen = Set<String>()
        // Any reviewed administrator prompt is encountered before other package updates start.
        let ordered = selected.sorted { $0.requiresAdministrator && !$1.requiresAdministrator }
        for old in ordered where seen.insert(old.id).inserted {
            do {
                try Task.checkCancellation()
                guard let fresh = current.packages.first(where: { $0.id == old.id }) else {
                    throw DevArtifactSafetyError("The package is no longer reported with this update. Check again.")
                }
                try validate(old, fresh: fresh)
                onOutput(
                    .standardOutput, Data(("\nUpdating " + old.version.title + "\n" + old.command.preview + "\n").utf8))
                let result = try await run(fresh, onOutput: onOutput)
                outcomes.append(
                    .init(
                        update: old, succeeded: result.didSucceed,
                        message: result.didSucceed
                            ? "Native update command completed." : "Native update failed (exit \(result.status))."))
            } catch {
                outcomes.append(.init(update: old, succeeded: false, message: error.localizedDescription))
                if error is CancellationError { break }
            }
        }
        return outcomes
    }

    private func validate(_ old: PackageUpdate, fresh: PackageUpdate) throws {
        guard old.isEligible, fresh.isEligible else {
            throw DevArtifactSafetyError(fresh.blockedReason ?? "This item is not authorized for automatic update.")
        }
        guard fresh.manager == old.manager, fresh.executableIdentity == old.executableIdentity,
            fresh.executableStamp == old.executableStamp, fresh.command == old.command,
            fresh.version.current == old.version.current, fresh.version.latest == old.version.latest,
            fresh.writableRoots == old.writableRoots, fresh.rootIdentities == old.rootIdentities
        else {
            throw DevArtifactSafetyError("Manager, install location or version changed since review. Check again.")
        }
        let identity = try UpdateProtection.identity(fresh.manager)
        guard identity.0 == fresh.executableIdentity, identity.1 == fresh.executableStamp else {
            throw DevArtifactSafetyError("The manager executable changed after inspection.")
        }
        guard fresh.rootIdentities == fresh.writableRoots.compactMap({ try? DevArtifactIdentity.read($0) }),
            fresh.rootIdentities.count == fresh.writableRoots.count
        else {
            throw DevArtifactSafetyError("An install location changed after inspection.")
        }
        if !fresh.requiresAdministrator, let reason = scanner.writableReason(fresh.writableRoots) {
            throw DevArtifactSafetyError(reason)
        }
    }

    private func run(_ update: PackageUpdate, onOutput: @escaping ProcessOutputHandler) async throws -> ProcessResult {
        if update.requiresAdministrator {
            guard let administratorUpdate, let appID = UInt64(update.version.identifier), appID > 0,
                let identity = update.executableIdentity, let stamp = update.executableStamp
            else {
                throw DevArtifactSafetyError("Administrator update support is unavailable. Use the App Store.")
            }
            return try await administratorUpdate(
                .init(
                    executable: update.manager.path, appID: appID,
                    executableIdentity: identity, executableStamp: stamp), onOutput)
        }
        return try await streamingRunner(update.command, onOutput)
    }
}
