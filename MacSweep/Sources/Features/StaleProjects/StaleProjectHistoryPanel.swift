import SwiftUI

struct StaleProjectHistoryPanel: View {
    let records: [StaleProjectActionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Project Actions").font(.headline)
            ForEach(records.prefix(10)) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.kind.rawValue + ": " + URL(fileURLWithPath: record.project).lastPathComponent)
                    Text(
                        "\(record.completedCount) completed · \(record.errors.count) failed · "
                            + record.timestamp.formatted(date: .abbreviated, time: .shortened)
                    )
                    .foregroundStyle(.secondary)
                    ForEach(record.errors, id: \.self) { Text($0).foregroundStyle(.secondary) }
                }.font(.caption)
            }
            Text(
                "Archive bytes are copied data. Artifact and checkout Trash estimates are separate; "
                    + "available-space changes may include other processes and are not attributed to these actions."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding().macSweepCard()
    }
}
