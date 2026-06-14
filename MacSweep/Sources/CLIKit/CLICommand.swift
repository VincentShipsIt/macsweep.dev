import Foundation
import MacSweepCore

public enum CLIOutputFormat: String, Sendable {
    case text
    case json
}

public enum CLICommand: Sendable, Equatable {
    case scan(HeadlessSelectionRequest, CLIOutputFormat)
    case dryRun(HeadlessSelectionRequest, CLIOutputFormat)
    case apply(HeadlessSelectionRequest, yes: Bool, format: CLIOutputFormat)
    case maintenance(String, CLIOutputFormat)
    case maintenanceList(CLIOutputFormat)
    case permissionsStatus(CLIOutputFormat)
    case modulesList(CLIOutputFormat)
    case version(CLIOutputFormat)
    case space(CLIOutputFormat)
    case spaceLens(path: String?, depth: Int, minSize: Int64, format: CLIOutputFormat)
    case loginItemsList(CLIOutputFormat)
    case loginItemSet(label: String, enabled: Bool, yes: Bool, format: CLIOutputFormat)
    case loginItemRemove(label: String, yes: Bool, format: CLIOutputFormat)
    case uninstallList(CLIOutputFormat)
    case uninstall(app: String, yes: Bool, format: CLIOutputFormat)
    case aiAnalysis(deep: Bool, format: CLIOutputFormat)
    case malwareScan(useAI: Bool, format: CLIOutputFormat)
    case homebrewOutdated(CLIOutputFormat)
    case homebrewUpgrade(yes: Bool, format: CLIOutputFormat)
    case homebrewCleanup(yes: Bool, format: CLIOutputFormat)
    case homebrewLeaves(CLIOutputFormat)
    case shred(path: String, level: String, yes: Bool, format: CLIOutputFormat)
    case wifiList(CLIOutputFormat)
    case wifiRemove(ssid: String, yes: Bool, format: CLIOutputFormat)
    case sshList(CLIOutputFormat)
    case sshRemove(host: String?, all: Bool, yes: Bool, format: CLIOutputFormat)
    case processesList(sort: String, format: CLIOutputFormat)
    case processesQuit(target: String, force: Bool, yes: Bool, format: CLIOutputFormat)
    case privacyClear(action: String, yes: Bool, format: CLIOutputFormat)
    case monitor(CLIOutputFormat)
    case help
}

public enum CLIParseError: Error, LocalizedError, Sendable, Equatable {
    case missingCommand
    case unknownCommand(String)
    case missingValue(String)
    case invalidValue(flag: String, value: String)
    case unexpectedArgument(String)
    case missingSubcommand(String)

    public var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "Missing command."
        case .unknownCommand(let command):
            return "Unknown command: \(command)."
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .invalidValue(let flag, let value):
            return "Invalid value '\(value)' for \(flag)."
        case .unexpectedArgument(let argument):
            return "Unexpected argument: \(argument)."
        case .missingSubcommand(let command):
            return "Missing subcommand for \(command)."
        }
    }
}

public enum CLICommandParser {
    public static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else {
            throw CLIParseError.missingCommand
        }

        switch command {
        case "scan":
            let (selection, format) = try parseSelection(arguments.dropFirst())
            return .scan(selection, format)
        case "dry-run":
            let (selection, format) = try parseSelection(arguments.dropFirst())
            return .dryRun(selection, format)
        case "apply":
            let (selection, format, yes) = try parseApply(arguments.dropFirst())
            return .apply(selection, yes: yes, format: format)
        case "maintenance":
            return try parseMaintenance(arguments.dropFirst())
        case "permissions":
            return try parsePermissions(arguments.dropFirst())
        case "modules":
            return try parseModules(arguments.dropFirst())
        case "version", "--version", "-v":
            return try parseVersion(arguments.dropFirst())
        case "space":
            return try parseSpace(arguments.dropFirst())
        case "login-items":
            return try parseLoginItems(arguments.dropFirst())
        case "uninstall":
            return try parseUninstall(arguments.dropFirst())
        case "ai":
            return try parseAI(arguments.dropFirst())
        case "malware":
            return try parseMalware(arguments.dropFirst())
        case "homebrew", "brew":
            return try parseHomebrew(arguments.dropFirst())
        case "shred":
            return try parseShred(arguments.dropFirst())
        case "network":
            return try parseNetwork(arguments.dropFirst())
        case "processes", "process":
            return try parseProcesses(arguments.dropFirst())
        case "privacy":
            return try parsePrivacy(arguments.dropFirst())
        case "monitor":
            return try parseMonitor(arguments.dropFirst())
        case "help", "--help", "-h":
            return .help
        default:
            throw CLIParseError.unknownCommand(command)
        }
    }

    /// Parses an optional trailing `--format <value>` from a slice that contains
    /// no positional arguments (the subcommand, if any, must already be dropped).
    private static func parseTrailingFormat(_ args: ArraySlice<String>) throws -> CLIOutputFormat {
        var format: CLIOutputFormat = .text
        var trailing = Array(args)
        while trailing.count >= 2 {
            let flag = trailing.removeFirst()
            if flag != "--format" {
                throw CLIParseError.unexpectedArgument(flag)
            }
            let value = trailing.removeFirst()
            guard let parsed = CLIOutputFormat(rawValue: value) else {
                throw CLIParseError.invalidValue(flag: "--format", value: value)
            }
            format = parsed
        }
        if let extra = trailing.first {
            throw CLIParseError.unexpectedArgument(extra)
        }
        return format
    }

    private static func parseSelection(_ args: ArraySlice<String>) throws -> (HeadlessSelectionRequest, CLIOutputFormat) {
        var moduleIDs: [String]?
        var smartCare = false
        var format: CLIOutputFormat = .text

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--modules":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--modules")
                }
                moduleIDs = value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            case "--smart-care":
                smartCare = true
            case "--format":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--format")
                }
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIParseError.invalidValue(flag: "--format", value: value)
                }
                format = parsed
            default:
                throw CLIParseError.unexpectedArgument(arg)
            }
        }

        return (HeadlessSelectionRequest(moduleIDs: moduleIDs, smartCare: smartCare), format)
    }

    private static func parseApply(_ args: ArraySlice<String>) throws -> (HeadlessSelectionRequest, CLIOutputFormat, Bool) {
        var yes = false
        var selectionArgs: [String] = []

        for arg in args {
            if arg == "--yes" {
                yes = true
            } else {
                selectionArgs.append(arg)
            }
        }

        let (selection, format) = try parseSelection(ArraySlice(selectionArgs))
        return (selection, format, yes)
    }

    private static func parseMaintenance(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("maintenance")
        }

        let format = try parseTrailingFormat(args.dropFirst())
        if subcommand == "list" {
            return .maintenanceList(format)
        }
        return .maintenance(subcommand, format)
    }

    private static func parsePermissions(_ args: ArraySlice<String>) throws -> CLICommand {
        guard args.first == "status" else {
            throw CLIParseError.missingSubcommand("permissions")
        }
        return .permissionsStatus(try parseTrailingFormat(args.dropFirst()))
    }

    private static func parseModules(_ args: ArraySlice<String>) throws -> CLICommand {
        guard args.first == "list" else {
            throw CLIParseError.missingSubcommand("modules")
        }
        return .modulesList(try parseTrailingFormat(args.dropFirst()))
    }

    private static func parseVersion(_ args: ArraySlice<String>) throws -> CLICommand {
        return .version(try parseTrailingFormat(args))
    }

    /// `space` → disk-usage summary; `space lens [path] [--depth N]` → tree.
    private static func parseSpace(_ args: ArraySlice<String>) throws -> CLICommand {
        if args.first == "lens" {
            return try parseSpaceLens(args.dropFirst())
        }
        return .space(try parseTrailingFormat(args))
    }

    private static func parseSpaceLens(_ args: ArraySlice<String>) throws -> CLICommand {
        var path: String?
        var depth = 2
        var minSize: Int64 = 0
        var format: CLIOutputFormat = .text

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--depth":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--depth")
                }
                guard let parsed = Int(value), (1...6).contains(parsed) else {
                    throw CLIParseError.invalidValue(flag: "--depth", value: value)
                }
                depth = parsed
            case "--min-size":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--min-size")
                }
                guard let parsed = parseByteSize(value) else {
                    throw CLIParseError.invalidValue(flag: "--min-size", value: value)
                }
                minSize = parsed
            case "--format":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--format")
                }
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIParseError.invalidValue(flag: "--format", value: value)
                }
                format = parsed
            default:
                if arg.hasPrefix("--") || path != nil {
                    throw CLIParseError.unexpectedArgument(arg)
                }
                path = arg
            }
        }
        return .spaceLens(path: path, depth: depth, minSize: minSize, format: format)
    }

    /// Parses a human byte-size token into bytes. Accepts a bare integer (bytes) or
    /// a value with a binary suffix: K/KB, M/MB, G/GB, T/TB (base 1024, matching
    /// `du -h`). Case-insensitive. Returns nil on any malformed input.
    static func parseByteSize(_ raw: String) -> Int64? {
        let token = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !token.isEmpty else { return nil }

        let multipliers: [(suffix: String, factor: Int64)] = [
            ("TB", 1 << 40), ("GB", 1 << 30), ("MB", 1 << 20), ("KB", 1 << 10),
            ("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10), ("B", 1)
        ]
        for (suffix, factor) in multipliers where token.hasSuffix(suffix) {
            let numberPart = String(token.dropLast(suffix.count))
            guard let value = Double(numberPart), value >= 0 else { return nil }
            return Int64(value * Double(factor))
        }
        // No recognized suffix → treat as a raw byte count.
        guard let bytes = Int64(token), bytes >= 0 else { return nil }
        return bytes
    }

    private static func parseLoginItems(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("login-items")
        }

        switch subcommand {
        case "list":
            return .loginItemsList(try parseTrailingFormat(args.dropFirst()))
        case "enable":
            let (label, yes, format) = try parseLoginItemMutation(args.dropFirst(), action: "enable")
            return .loginItemSet(label: label, enabled: true, yes: yes, format: format)
        case "disable":
            let (label, yes, format) = try parseLoginItemMutation(args.dropFirst(), action: "disable")
            return .loginItemSet(label: label, enabled: false, yes: yes, format: format)
        case "remove":
            let (label, yes, format) = try parseLoginItemMutation(args.dropFirst(), action: "remove")
            return .loginItemRemove(label: label, yes: yes, format: format)
        default:
            throw CLIParseError.unknownCommand("login-items \(subcommand)")
        }
    }

    /// Parse `<label> [--yes] [--format ...]` for a login-items mutation. The
    /// positional `<label>` is the launchd Label (quote it if it contains spaces).
    private static func parseLoginItemMutation(
        _ args: ArraySlice<String>,
        action: String
    ) throws -> (label: String, yes: Bool, format: CLIOutputFormat) {
        var label: String?
        var yes = false
        var format: CLIOutputFormat = .text

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--yes":
                yes = true
            case "--format":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--format")
                }
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIParseError.invalidValue(flag: "--format", value: value)
                }
                format = parsed
            default:
                if arg.hasPrefix("--") || label != nil {
                    throw CLIParseError.unexpectedArgument(arg)
                }
                label = arg
            }
        }

        guard let resolved = label else {
            throw CLIParseError.missingValue("login-items \(action) <label>")
        }
        return (resolved, yes, format)
    }

    private static func parseUninstall(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let first = args.first else {
            throw CLIParseError.missingSubcommand("uninstall")
        }

        if first == "list" {
            return .uninstallList(try parseTrailingFormat(args.dropFirst()))
        }

        // Positional <app> (quote names with spaces) plus optional --yes/--format.
        var appQuery: String?
        var yes = false
        var format: CLIOutputFormat = .text

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--yes":
                yes = true
            case "--format":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--format")
                }
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIParseError.invalidValue(flag: "--format", value: value)
                }
                format = parsed
            default:
                if arg.hasPrefix("--") || appQuery != nil {
                    throw CLIParseError.unexpectedArgument(arg)
                }
                appQuery = arg
            }
        }

        guard let resolved = appQuery else {
            throw CLIParseError.missingValue("<app>")
        }
        return .uninstall(app: resolved, yes: yes, format: format)
    }

    private static func parseAI(_ args: ArraySlice<String>) throws -> CLICommand {
        // `ai [scan] [--ai|--deep] [--format ...]`. The "scan" subcommand is
        // optional sugar; --ai/--deep opt into the gated semantic pass.
        var deep = false
        var rest: [String] = []
        var sawSubcommand = false
        for arg in args {
            switch arg {
            case "scan" where !sawSubcommand:
                sawSubcommand = true
            case "--ai", "--deep":
                deep = true
            default:
                rest.append(arg)
            }
        }
        return .aiAnalysis(deep: deep, format: try parseTrailingFormat(ArraySlice(rest)))
    }

    private static func parseMalware(_ args: ArraySlice<String>) throws -> CLICommand {
        guard args.first == "scan" else {
            throw CLIParseError.missingSubcommand("malware")
        }

        var useAI = false
        var rest: [String] = []
        for arg in args.dropFirst() {
            if arg == "--ai" {
                useAI = true
            } else {
                rest.append(arg)
            }
        }
        return .malwareScan(useAI: useAI, format: try parseTrailingFormat(ArraySlice(rest)))
    }

    private static func parseHomebrew(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("homebrew")
        }

        switch subcommand {
        case "outdated":
            return .homebrewOutdated(try parseTrailingFormat(args.dropFirst()))
        case "upgrade":
            var yes = false
            var rest: [String] = []
            for arg in args.dropFirst() {
                if arg == "--yes" {
                    yes = true
                } else {
                    rest.append(arg)
                }
            }
            return .homebrewUpgrade(yes: yes, format: try parseTrailingFormat(ArraySlice(rest)))
        case "cleanup":
            var yes = false
            var rest: [String] = []
            for arg in args.dropFirst() {
                if arg == "--yes" {
                    yes = true
                } else {
                    rest.append(arg)
                }
            }
            return .homebrewCleanup(yes: yes, format: try parseTrailingFormat(ArraySlice(rest)))
        case "leaves":
            return .homebrewLeaves(try parseTrailingFormat(args.dropFirst()))
        default:
            throw CLIParseError.unknownCommand("homebrew \(subcommand)")
        }
    }

    private static func parseShred(_ args: ArraySlice<String>) throws -> CLICommand {
        var path: String?
        var level = "standard"
        var yes = false
        var format: CLIOutputFormat = .text

        let validLevels: Set<String> = ["quick", "standard", "secure", "paranoid"]

        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--level":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--level")
                }
                let normalized = value.lowercased()
                guard validLevels.contains(normalized) else {
                    throw CLIParseError.invalidValue(flag: "--level", value: value)
                }
                level = normalized
            case "--yes":
                yes = true
            case "--format":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--format")
                }
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIParseError.invalidValue(flag: "--format", value: value)
                }
                format = parsed
            default:
                if arg.hasPrefix("--") || path != nil {
                    throw CLIParseError.unexpectedArgument(arg)
                }
                path = arg
            }
        }

        guard let resolvedPath = path else {
            throw CLIParseError.missingValue("<path>")
        }
        return .shred(path: resolvedPath, level: level, yes: yes, format: format)
    }

    // MARK: - network

    /// `network wifi …` and `network ssh …`.
    private static func parseNetwork(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("network")
        }
        switch subcommand {
        case "wifi":
            return try parseWiFi(args.dropFirst())
        case "ssh":
            return try parseSSH(args.dropFirst())
        default:
            throw CLIParseError.unknownCommand("network \(subcommand)")
        }
    }

    /// `network wifi list` / `network wifi remove [--ssid] <ssid>`.
    private static func parseWiFi(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("network wifi")
        }
        switch subcommand {
        case "list":
            return .wifiList(try parseTrailingFormat(args.dropFirst()))
        case "remove":
            var ssid: String?
            var yes = false
            var format: CLIOutputFormat = .text
            var iterator = args.dropFirst().makeIterator()
            while let arg = iterator.next() {
                switch arg {
                case "--ssid":
                    guard let value = iterator.next() else {
                        throw CLIParseError.missingValue("--ssid")
                    }
                    ssid = value
                case "--yes":
                    yes = true
                case "--format":
                    guard let value = iterator.next() else {
                        throw CLIParseError.missingValue("--format")
                    }
                    guard let parsed = CLIOutputFormat(rawValue: value) else {
                        throw CLIParseError.invalidValue(flag: "--format", value: value)
                    }
                    format = parsed
                default:
                    if arg.hasPrefix("--") || ssid != nil {
                        throw CLIParseError.unexpectedArgument(arg)
                    }
                    ssid = arg
                }
            }
            guard let resolved = ssid else {
                throw CLIParseError.missingValue("--ssid")
            }
            return .wifiRemove(ssid: resolved, yes: yes, format: format)
        default:
            throw CLIParseError.unknownCommand("network wifi \(subcommand)")
        }
    }

    /// `network ssh list` / `network ssh remove (--host <h> | --all)`.
    private static func parseSSH(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("network ssh")
        }
        switch subcommand {
        case "list":
            return .sshList(try parseTrailingFormat(args.dropFirst()))
        case "remove":
            var host: String?
            var all = false
            var yes = false
            var format: CLIOutputFormat = .text
            var iterator = args.dropFirst().makeIterator()
            while let arg = iterator.next() {
                switch arg {
                case "--host":
                    guard let value = iterator.next() else {
                        throw CLIParseError.missingValue("--host")
                    }
                    host = value
                case "--all":
                    all = true
                case "--yes":
                    yes = true
                case "--format":
                    guard let value = iterator.next() else {
                        throw CLIParseError.missingValue("--format")
                    }
                    guard let parsed = CLIOutputFormat(rawValue: value) else {
                        throw CLIParseError.invalidValue(flag: "--format", value: value)
                    }
                    format = parsed
                default:
                    if arg.hasPrefix("--") || host != nil {
                        throw CLIParseError.unexpectedArgument(arg)
                    }
                    host = arg
                }
            }
            // Exactly one of --host / --all.
            if all && host != nil {
                throw CLIParseError.unexpectedArgument("--all")
            }
            if !all && host == nil {
                throw CLIParseError.missingValue("--host or --all")
            }
            return .sshRemove(host: host, all: all, yes: yes, format: format)
        default:
            throw CLIParseError.unknownCommand("network ssh \(subcommand)")
        }
    }

    // MARK: - processes

    /// `processes list [--sort memory|cpu|name]` / `processes quit <pid|name> [--force]`.
    private static func parseProcesses(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("processes")
        }
        switch subcommand {
        case "list":
            var sort = "memory"
            var format: CLIOutputFormat = .text
            let validSorts: Set<String> = ["memory", "cpu", "name"]
            var iterator = args.dropFirst().makeIterator()
            while let arg = iterator.next() {
                switch arg {
                case "--sort":
                    guard let value = iterator.next() else {
                        throw CLIParseError.missingValue("--sort")
                    }
                    let normalized = value.lowercased()
                    guard validSorts.contains(normalized) else {
                        throw CLIParseError.invalidValue(flag: "--sort", value: value)
                    }
                    sort = normalized
                case "--format":
                    guard let value = iterator.next() else {
                        throw CLIParseError.missingValue("--format")
                    }
                    guard let parsed = CLIOutputFormat(rawValue: value) else {
                        throw CLIParseError.invalidValue(flag: "--format", value: value)
                    }
                    format = parsed
                default:
                    throw CLIParseError.unexpectedArgument(arg)
                }
            }
            return .processesList(sort: sort, format: format)
        case "quit":
            var target: String?
            var force = false
            var yes = false
            var format: CLIOutputFormat = .text
            var iterator = args.dropFirst().makeIterator()
            while let arg = iterator.next() {
                switch arg {
                case "--force":
                    force = true
                case "--yes":
                    yes = true
                case "--format":
                    guard let value = iterator.next() else {
                        throw CLIParseError.missingValue("--format")
                    }
                    guard let parsed = CLIOutputFormat(rawValue: value) else {
                        throw CLIParseError.invalidValue(flag: "--format", value: value)
                    }
                    format = parsed
                default:
                    if arg.hasPrefix("--") || target != nil {
                        throw CLIParseError.unexpectedArgument(arg)
                    }
                    target = arg
                }
            }
            guard let resolved = target else {
                throw CLIParseError.missingValue("processes quit <pid|name>")
            }
            return .processesQuit(target: resolved, force: force, yes: yes, format: format)
        default:
            throw CLIParseError.unknownCommand("processes \(subcommand)")
        }
    }

    // MARK: - privacy

    /// `privacy clear-clipboard|clear-terminal-history|clear-recent-docs [--yes]`.
    private static func parsePrivacy(_ args: ArraySlice<String>) throws -> CLICommand {
        guard let subcommand = args.first else {
            throw CLIParseError.missingSubcommand("privacy")
        }
        let validActions: Set<String> = [
            "clear-clipboard", "clear-terminal-history", "clear-recent-docs",
        ]
        guard validActions.contains(subcommand) else {
            throw CLIParseError.unknownCommand("privacy \(subcommand)")
        }
        var yes = false
        var format: CLIOutputFormat = .text
        var iterator = args.dropFirst().makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--yes":
                yes = true
            case "--format":
                guard let value = iterator.next() else {
                    throw CLIParseError.missingValue("--format")
                }
                guard let parsed = CLIOutputFormat(rawValue: value) else {
                    throw CLIParseError.invalidValue(flag: "--format", value: value)
                }
                format = parsed
            default:
                throw CLIParseError.unexpectedArgument(arg)
            }
        }
        return .privacyClear(action: subcommand, yes: yes, format: format)
    }

    // MARK: - monitor

    /// `monitor [--format json|text]` → one-shot system snapshot.
    private static func parseMonitor(_ args: ArraySlice<String>) throws -> CLICommand {
        return .monitor(try parseTrailingFormat(args))
    }
}

public enum CLIHelp {
    public static let text = """
    macsweep

    Commands:
      macsweep scan [--modules <csv>] [--smart-care] [--format json|text]
      macsweep dry-run [--modules <csv>] [--smart-care] [--format json|text]
      macsweep apply [--modules <csv>] [--smart-care] [--yes] [--format json|text]
      macsweep maintenance <action> [--format json|text]
      macsweep maintenance list [--format json|text]
      macsweep permissions status [--format json|text]
      macsweep modules list [--format json|text]
      macsweep space [--format json|text]
      macsweep space lens [path] [--depth 1-6] [--min-size SIZE] [--format json|text]
      macsweep login-items list [--format json|text]
      macsweep login-items enable <label> [--yes] [--format json|text]
      macsweep login-items disable <label> [--yes] [--format json|text]
      macsweep login-items remove <label> [--yes] [--format json|text]
      macsweep uninstall list [--format json|text]
      macsweep uninstall <app> [--yes] [--format json|text]
      macsweep ai [scan] [--deep] [--format json|text]
      macsweep malware scan [--ai] [--format json|text]
      macsweep homebrew outdated [--format json|text]
      macsweep homebrew upgrade [--yes] [--format json|text]
      macsweep homebrew cleanup [--yes] [--format json|text]
      macsweep homebrew leaves [--format json|text]
      macsweep shred <path> [--level quick|standard|secure|paranoid] [--yes] [--format json|text]
      macsweep network wifi list [--format json|text]
      macsweep network wifi remove --ssid <ssid> [--yes] [--format json|text]
      macsweep network ssh list [--format json|text]
      macsweep network ssh remove (--host <host> | --all) [--yes] [--format json|text]
      macsweep processes list [--sort memory|cpu|name] [--format json|text]
      macsweep processes quit <pid|name> [--force] [--yes] [--format json|text]
      macsweep privacy clear-clipboard [--yes] [--format json|text]
      macsweep privacy clear-terminal-history [--yes] [--format json|text]
      macsweep privacy clear-recent-docs [--yes] [--format json|text]
      macsweep monitor [--format json|text]
      macsweep version [--format json|text]
    """
}
