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
    case permissionsStatus(CLIOutputFormat)
    case modulesList(CLIOutputFormat)
    case help
}

public enum CLIParseError: Error, LocalizedError, Sendable {
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
        case "help", "--help", "-h":
            return .help
        default:
            throw CLIParseError.unknownCommand(command)
        }
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

        var format: CLIOutputFormat = .text
        var trailing = Array(args.dropFirst())
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

        return .maintenance(subcommand, format)
    }

    private static func parsePermissions(_ args: ArraySlice<String>) throws -> CLICommand {
        guard args.first == "status" else {
            throw CLIParseError.missingSubcommand("permissions")
        }

        var format: CLIOutputFormat = .text
        var trailing = Array(args.dropFirst())
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

        return .permissionsStatus(format)
    }

    private static func parseModules(_ args: ArraySlice<String>) throws -> CLICommand {
        guard args.first == "list" else {
            throw CLIParseError.missingSubcommand("modules")
        }

        var format: CLIOutputFormat = .text
        var trailing = Array(args.dropFirst())
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

        return .modulesList(format)
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
      macsweep permissions status [--format json|text]
      macsweep modules list [--format json|text]
    """
}
