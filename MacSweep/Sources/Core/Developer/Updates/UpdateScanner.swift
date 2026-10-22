import Foundation

struct UpdateScanner: Sendable {
    var managerPath: @Sendable (String) -> String? = { UpdateCommands.manager($0) }
    var administratorAvailable = false
    var masExecutableAllowed: @Sendable (String) -> Bool = {
        ["/opt/homebrew/bin/mas", "/usr/local/bin/mas", "/opt/local/bin/mas"].contains($0)
    }
    var homebrewNoSudo: @Sendable (URL) -> Bool = { UpdateProtection.hasHomebrewNoSudo(manager: $0) }
    var writableReason: @Sendable ([URL]) -> String? = { UpdateProtection.writableReason($0) }
    var commandRunner: UpdateCommandRunner = { command, timeout in
        try await ProcessRunner.run(
            executable: command.executable, arguments: command.arguments,
            currentDirectory: URL(fileURLWithPath: "/"), timeout: timeout)
    }

    func scan(sources: [UpdateSource] = UpdateSource.allCases) async throws -> UpdateInventory {
        var inventory = UpdateInventory()
        var brewOutput: ProcessResult?
        for source in sources {
            try Task.checkCancellation()
            guard let manager = managerPath(source.tool) else {
                inventory.reports.append(.init(source: source, message: source.installHint, isError: false))
                continue
            }
            do {
                let output: ProcessResult
                if let cached = brewOutput, source == .brewCask {
                    output = cached
                } else {
                    output = try await commandRunner(UpdateCommands.outdated(source, manager: manager), 60)
                }
                if source == .brewFormula { brewOutput = output }
                try validateOutput(output, source: source)
                let versions = try await versions(output.output, source: source, manager: manager)
                let scope: UpdateProtection.Scope
                do { scope = try await self.scope(source: source, manager: manager) } catch {
                    scope = .init(reason: "Install-location or privilege inspection is incomplete. Update manually.")
                }
                for version in versions {
                    inventory.packages.append(await package(version, source: source, manager: manager, scope: scope))
                }
                inventory.reports.append(
                    .init(
                        source: source,
                        message: versions.isEmpty
                            ? "No outdated items reported." : "\(versions.count) update(s) reported.", isError: false))
            } catch is CancellationError { throw CancellationError() } catch {
                inventory.reports.append(.init(source: source, message: error.localizedDescription, isError: true))
            }
        }
        return inventory
    }

    private func validateOutput(_ output: ProcessResult, source: UpdateSource) throws {
        let allowed = [UpdateSource.npm, .pnpm].contains(source) ? [Int32(0), 1] : [Int32(0)]
        guard allowed.contains(output.status), output.outputWasValidUTF8, output.output.utf8.count <= 4_194_304 else {
            throw DevArtifactSafetyError(
                "\(source.title) check failed (exit \(output.status)). No updates were inferred.")
        }
    }

    private func versions(_ text: String, source: UpdateSource, manager: String) async throws -> [UpdateVersion] {
        switch source {
        case .brewFormula, .brewCask: return try UpdateParsers.brew(text, source: source)
        case .mas: return try UpdateParsers.mas(text)
        case .npm, .pnpm: return try UpdateParsers.node(text)
        case .gem: return try UpdateParsers.gem(text)
        case .pipx: return try await pipxVersions(text, manager: manager)
        }
    }

    private func pipxVersions(_ text: String, manager: String) async throws -> [UpdateVersion] {
        let apps = try UpdateParsers.pipxApps(text)
        guard apps.count <= 100 else {
            throw DevArtifactSafetyError("pipx inventory exceeds the 100-environment inspection limit.")
        }
        var versions: [UpdateVersion] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        for app in apps {
            try Task.checkCancellation()
            guard UpdateParsers.validName(app.environment, source: .pipx),
                ProcessInfo.processInfo.systemUptime < deadline
            else {
                throw DevArtifactSafetyError("pipx environment inspection is unsupported or incomplete.")
            }
            let args = ["runpip", app.environment, "list", "--outdated", "--format=json", "--disable-pip-version-check"]
            let output = try await commandRunner(UpdateCommands.command(manager, args, source: .pipx), 30)
            try validateOutput(output, source: .pipx)
            if var version = try UpdateParsers.pipxOutdated(output.output, app: app) {
                if app.pinned { version.retainedReason = "Pinned in pipx. Unpin it manually before updating." }
                versions.append(version)
            }
        }
        return versions
    }

    private func package(
        _ version: UpdateVersion, source: UpdateSource, manager: String,
        scope initialScope: UpdateProtection.Scope
    ) async -> PackageUpdate {
        let executable = URL(fileURLWithPath: manager)
        let identity = try? UpdateProtection.identity(executable)
        var scope = initialScope
        scope.reason = version.retainedReason ?? scope.reason
        if source == .brewCask, UpdateParsers.validName(version.identifier, source: source) {
            do {
                let metadata = try await commandRunner(
                    UpdateCommands.command(
                        manager,
                        ["info", "--json=v2", "--cask", version.identifier], source: source), 15)
                let needsAdministrator = try UpdateProtection.caskRequiresAdministrator(metadata.output)
                if !metadata.didSucceed || needsAdministrator {
                    scope.reason =
                        "This cask has installer actions requiring manual administrator review. Update it in Homebrew."
                }
            } catch { scope.reason = "Cask installer privilege requirements are unknown. Update this item manually." }
        }
        if !UpdateParsers.validName(version.identifier, source: source)
            || ([UpdateSource.npm, .pnpm].contains(source) && !UpdateParsers.validVersion(version.latest)) {
            scope.reason = "The native package identifier or target version is unsupported. Update this item manually."
        }
        return PackageUpdate(
            source: source, version: version,
            command: UpdateCommands.upgrade(version, source: source, manager: manager), manager: executable,
            executableIdentity: identity?.0, executableStamp: identity?.1, writableRoots: scope.roots,
            rootIdentities: scope.roots.compactMap { try? DevArtifactIdentity.read($0) },
            blockedReason: scope.reason)
    }

    private func scope(source: UpdateSource, manager: String) async throws -> UpdateProtection.Scope {
        if source == .mas {
            let known = masExecutableAllowed(manager)
            let reason =
                administratorAvailable && known
                ? nil
                : "Administrator update support is unavailable. Sign in and update this app using the App Store."
            return .init(reason: reason)
        }
        var roots = try await installRoots(source: source, manager: manager)
        var reason = writableReason(roots)
        if source == .brewFormula || source == .brewCask {
            if !homebrewNoSudo(URL(fileURLWithPath: manager)) {
                reason = "This Homebrew cannot prove noninteractive, no-sudo updates. Upgrade Homebrew manually first."
            }
            if source == .brewCask {
                roots.append(URL(fileURLWithPath: "/Applications"))
                reason = reason ?? writableReason(roots)
            }
        }
        return .init(roots: roots, reason: reason)
    }

    private func installRoots(source: UpdateSource, manager: String) async throws -> [URL] {
        let queries: [[String]]
        switch source {
        case .brewFormula, .brewCask: queries = [["--prefix"]]
        case .npm: queries = [["prefix", "--global"], ["root", "--global"]]
        case .pnpm: queries = [["root", "--global"], ["bin", "--global"]]
        case .pipx: queries = [["environment", "--value", "PIPX_HOME"], ["environment", "--value", "PIPX_BIN_DIR"]]
        case .gem: queries = [["environment", "gemdir", "--norc"]]
        case .mas: return []
        }
        var roots: [URL] = []
        for query in queries {
            let result = try await commandRunner(UpdateCommands.command(manager, query, source: source), 10)
            roots.append(try UpdateProtection.absolutePath(result))
        }
        if source == .brewFormula, let prefix = roots.first {
            roots += [prefix.appendingPathComponent("Cellar"), prefix.appendingPathComponent("bin")]
        }
        if source == .brewCask, let prefix = roots.first { roots.append(prefix.appendingPathComponent("Caskroom")) }
        return roots
    }
}
