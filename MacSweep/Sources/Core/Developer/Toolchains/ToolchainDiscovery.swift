import Foundation

enum ToolchainDiscovery {
    static func locations(home: URL, environment: [String: String]) -> [ToolchainLocation] {
        func root(_ key: String, _ fallback: String) -> URL {
            if let value = environment[key], value.hasPrefix("/") { return URL(fileURLWithPath: value) }
            return home.appendingPathComponent(fallback)
        }
        func executable(_ manager: ToolchainManager, _ root: URL) -> URL? {
            let paths = [
                root.appendingPathComponent("bin/" + manager.rawValue),
                home.appendingPathComponent(".cargo/bin/" + manager.rawValue),
                home.appendingPathComponent(".local/bin/" + manager.rawValue),
                URL(fileURLWithPath: "/opt/homebrew/bin/" + manager.rawValue),
                URL(fileURLWithPath: "/usr/local/bin/" + manager.rawValue)
            ]
            return paths.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        let roots: [(ToolchainManager, URL)] = [
            (.nvm, root("NVM_DIR", ".nvm")), (.pyenv, root("PYENV_ROOT", ".pyenv")),
            (.rbenv, root("RBENV_ROOT", ".rbenv")), (.asdf, root("ASDF_DATA_DIR", ".asdf")),
            (.mise, root("MISE_DATA_DIR", ".local/share/mise")), (.rustup, root("RUSTUP_HOME", ".rustup"))
        ]
        var locations = roots.map { manager, directory in
            ToolchainLocation(
                manager: manager, root: directory,
                executable: manager == .nvm
                    ? directory.appendingPathComponent("nvm.sh") : executable(manager, directory))
        }
        locations += [
            home.appendingPathComponent("Library/Java/JavaVirtualMachines"),
            home.appendingPathComponent("Library/Java"), URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")
        ].map {
            ToolchainLocation(manager: .java, root: $0, executable: nil)
        }
        return locations
    }

    static func candidates(_ location: ToolchainLocation) throws -> [ToolchainCandidate] {
        let fileManager = FileManager.default
        func children(_ path: URL) throws -> [URL] {
            guard fileManager.fileExists(atPath: path.path) else { return [] }
            let children = try fileManager.contentsOfDirectory(
                at: path, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
            guard children.count <= 4096 else { throw DevArtifactSafetyError("Runtime inventory exceeds its limit.") }
            return children.sorted { $0.path < $1.path }
        }
        switch location.manager {
        case .nvm:
            return try children(location.root.appendingPathComponent("versions/node")).map {
                ToolchainCandidate(tool: "node", version: $0.lastPathComponent, path: $0)
            }
        case .pyenv, .rbenv:
            let tool = location.manager == .pyenv ? "python" : "ruby"
            return try children(location.root.appendingPathComponent("versions")).map {
                ToolchainCandidate(tool: tool, version: $0.lastPathComponent, path: $0)
            }
        case .rustup:
            return try children(location.root.appendingPathComponent("toolchains")).map {
                ToolchainCandidate(tool: "rust", version: $0.lastPathComponent, path: $0)
            }
        case .asdf, .mise:
            return try children(location.root.appendingPathComponent("installs")).flatMap { tool in
                try children(tool).map {
                    ToolchainCandidate(tool: tool.lastPathComponent, version: $0.lastPathComponent, path: $0)
                }
            }
        case .java:
            return try children(location.root).filter { $0.pathExtension == "jdk" }.map {
                ToolchainCandidate(tool: "java", version: $0.lastPathComponent, path: $0)
            }
        }
    }

    static func command(location: ToolchainLocation, tool: String, version: String) -> ToolchainCommand? {
        guard ToolchainReferenceParser.validIdentifier(tool), ToolchainReferenceParser.validVersion(version),
            let executable = location.executable,
            FileManager.default.fileExists(atPath: executable.path)
        else { return nil }
        switch location.manager {
        case .pyenv, .rbenv: return wrapped(location, arguments: ["uninstall", "-f", version])
        case .asdf: return wrapped(location, arguments: ["uninstall", tool, version])
        case .rustup: return wrapped(location, arguments: ["toolchain", "uninstall", version])
        case .nvm:
            // This fixed launcher does not load profiles. Manager path and version are positional data.
            return .init(
                executable: "/usr/bin/env",
                arguments: cleanEnvironment(location) + [
                    "/bin/bash", "--noprofile", "--norc", "-c", nvmScript, "macsweep-nvm", location.root.path, version
                ])
        case .mise:
            return wrapped(
                location, arguments: ["--no-config", "--no-env", "--no-hooks", "uninstall", tool + "@" + version])
        case .java: return nil
        }
    }

    private static func wrapped(_ location: ToolchainLocation, arguments: [String]) -> ToolchainCommand? {
        guard let executable = location.executable else { return nil }
        return .init(executable: "/usr/bin/env", arguments: cleanEnvironment(location) + [executable.path] + arguments)
    }

    private static func cleanEnvironment(_ location: ToolchainLocation) -> [String] {
        let rootKey: String
        switch location.manager {
        case .nvm: rootKey = "NVM_DIR"
        case .pyenv: rootKey = "PYENV_ROOT"
        case .rbenv: rootKey = "RBENV_ROOT"
        case .asdf: rootKey = "ASDF_DATA_DIR"
        case .mise: rootKey = "MISE_DATA_DIR"
        case .rustup: rootKey = "RUSTUP_HOME"
        case .java: rootKey = "JAVA_HOME"
        }
        return [
            "-i", "HOME=" + FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", rootKey + "=" + location.root.path
        ]
    }

    static let nvmScript = #"export NVM_DIR="$1"; . "$NVM_DIR/nvm.sh" --no-use || exit 1; nvm uninstall "$2""#
}
