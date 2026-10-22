import Foundation

enum LocalSnapshotParsing {
    static func snapshots(_ output: String) throws -> [LocalTimeMachineSnapshot] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == "Snapshots for disk /:", lines.count <= 4097 else {
            throw LocalSnapshotError("Snapshot listing has an unsupported format or size.")
        }
        var snapshots: [LocalTimeMachineSnapshot] = []
        for line in lines.dropFirst() {
            let suffix = " (dataless)"
            let dataless = line.hasSuffix(suffix)
            let name = dataless ? String(line.dropLast(suffix.count)) : line
            let prefix = "com.apple.TimeMachine."
            guard name.hasPrefix(prefix), name.hasSuffix(".local") else {
                throw LocalSnapshotError("Unknown snapshot records are retained; thinning is disabled.")
            }
            let token = String(name.dropFirst(prefix.count).dropLast(".local".count))
            let date = try parseDate(token)
            snapshots.append(
                LocalTimeMachineSnapshot(name: name, dateToken: token, created: date, isDataless: dataless))
        }
        guard Set(snapshots.map(\.id)).count == snapshots.count else {
            throw LocalSnapshotError("Duplicate snapshot identifiers; thinning is disabled.")
        }
        return snapshots.sorted { $0.dateToken > $1.dateToken }
    }

    static func parseDate(_ token: String) throws -> Date {
        guard token.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$"#, options: .regularExpression) != nil else {
            throw LocalSnapshotError("Invalid snapshot date.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.isLenient = false
        guard let date = formatter.date(from: token), formatter.string(from: date) == token else {
            throw LocalSnapshotError("Invalid snapshot calendar date.")
        }
        return date
    }

    static func backupRunning(_ output: String) throws -> Bool {
        guard let start = output.firstIndex(of: "{") else {
            throw LocalSnapshotError("Time Machine backup activity is unknown.")
        }
        let data = Data(output[start...].utf8)
        guard let properties = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let raw = properties["Running"]
        else {
            throw LocalSnapshotError("Time Machine backup activity is unknown.")
        }
        if let number = raw as? NSNumber, [0, 1].contains(number.intValue),
            number.doubleValue == Double(number.intValue) {
            return number.intValue == 1
        }
        if let value = raw as? String, ["0", "1"].contains(value) { return value == "1" }
        throw LocalSnapshotError("Time Machine backup activity is unknown.")
    }

    static func volume(_ output: String) throws -> String {
        guard let data = output.data(using: .utf8),
            let properties = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            properties["FilesystemType"] as? String == "apfs", properties["MountPoint"] as? String == "/",
            let id = properties["VolumeUUID"] as? String, UUID(uuidString: id) != nil
        else {
            throw LocalSnapshotError("The startup APFS volume identity could not be verified.")
        }
        return id
    }
}
