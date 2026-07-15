import AppKit
import SwiftUI

struct DeveloperLogsView: View {
    @State private var allEvents: [AppLogEvent] = []
    @State private var displayedEvents: [AppLogEvent] = []
    @State private var selectedCategory: AppLogCategory?
    @State private var searchText = ""
    @State private var showingClearConfirmation = false
    @State private var hasLogFile = false

    private let store = AppLogStore.shared
    private let loadsPersistentLogs: Bool

    init(snapshotEvents: [AppLogEvent]? = nil) {
#if SWIFT_PACKAGE
        loadsPersistentLogs = false
        let initialEvents = snapshotEvents ?? []
#else
        loadsPersistentLogs = snapshotEvents == nil
        let initialEvents = snapshotEvents ?? []
#endif
        let sortedEvents = initialEvents.sorted { $0.timestamp > $1.timestamp }
        _allEvents = State(initialValue: sortedEvents)
        _displayedEvents = State(initialValue: sortedEvents)
    }

    var body: some View {
        FeaturePageShell(
            title: "Developer Logs",
            subtitle: "Local deletion audit and diagnostic events",
            trailing: AnyView(refreshButton)
        ) {
            VStack(spacing: 0) {
                controls
                Divider()

                if displayedEvents.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search paths, modules, errors")
        .onAppear(perform: refresh)
        .onChange(of: searchText) { applyFilters() }
        .onChange(of: selectedCategory) { applyFilters() }
        .confirmationDialog(
            "Clear the local log?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Log", role: .destructive) {
                store.clear()
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes MacSweep's app-owned audit file. "
                    + "macOS unified logs are managed separately by the system."
            )
        }
    }

    private var refreshButton: some View {
        Button(action: refresh) {
            Label("Refresh Logs", systemImage: "arrow.clockwise")
        }
        .disabled(!loadsPersistentLogs)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            LogSummaryView(
                eventCount: allEvents.count,
                deletionCount: allEvents.count { $0.category == .deletion },
                errorCount: allEvents.count { $0.level == .error }
            )

            HStack(spacing: 12) {
                Picker("Category", selection: $selectedCategory) {
                    Text("All").tag(nil as AppLogCategory?)
                    ForEach(AppLogCategory.allCases) { category in
                        Text(category.displayName).tag(Optional(category))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)

                Spacer()

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(!hasLogFile)
                .help("Reveal the newline-delimited JSON log in Finder")

                ShareLink(item: store.fileURL) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(!hasLogFile)
                .help("Export the local log file")

                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .glassButton()
                .controlSize(.small)
                .disabled(!loadsPersistentLogs || allEvents.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var eventList: some View {
        List(displayedEvents) { event in
            DeveloperLogRow(event: event)
        }
        .listStyle(.inset)
        .macSweepListSurface()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                allEvents.isEmpty ? "No Log Events" : "No Matching Events",
                systemImage: allEvents.isEmpty ? "list.bullet.rectangle" : "magnifyingglass"
            )
        } description: {
            if allEvents.isEmpty {
                Text("Deletion attempts and diagnostic failures will appear here automatically.")
            } else {
                Text("Try a different search or category filter.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        guard loadsPersistentLogs else {
            applyFilters()
            return
        }
        allEvents = store.events.sorted { $0.timestamp > $1.timestamp }
        hasLogFile = FileManager.default.fileExists(atPath: store.fileURL.path)
        applyFilters()
    }

    private func applyFilters() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        displayedEvents = allEvents.filter { event in
            let matchesCategory = selectedCategory == nil || event.category == selectedCategory
            let matchesSearch = query.isEmpty
                || event.searchableText.localizedCaseInsensitiveContains(query)
            return matchesCategory && matchesSearch
        }
    }
}

private struct LogSummaryView: View {
    let eventCount: Int
    let deletionCount: Int
    let errorCount: Int

    var body: some View {
        HStack(spacing: 18) {
            Label("\(eventCount) events", systemImage: "list.bullet.rectangle")
            Label("\(deletionCount) deletions", systemImage: "trash")
            Label("\(errorCount) errors", systemImage: "exclamationmark.triangle")
                .foregroundStyle(errorCount > 0 ? .orange : .secondary)
            Spacer()
            Text("Local only · newest first")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

private struct DeveloperLogRow: View {
    let event: AppLogEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 20)
                .accessibilityLabel(levelLabel)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.message)
                        .fontWeight(.medium)
                    Spacer()
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let path = event.path {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                if let errorMessage = event.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var metadata: String {
        var values = [event.category.displayName]
        if let module = event.module { values.append(module) }
        if let action = event.action { values.append(action) }
        return values.joined(separator: " · ")
    }

    private var icon: String {
        switch event.level {
        case .debug: return "info.circle"
        case .notice: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch event.level {
        case .debug: return .secondary
        case .notice: return MacSweepTheme.accent
        case .error: return .orange
        }
    }

    private var levelLabel: String {
        switch event.level {
        case .debug: return "Debug"
        case .notice: return "Completed"
        case .error: return "Error"
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    DeveloperLogsView(snapshotEvents: [
        AppLogEvent(
            category: .deletion,
            level: .notice,
            message: "Moved to Trash",
            module: "dev-tools",
            path: "/Users/example/Project/.build",
            action: "trash"
        ),
        AppLogEvent(
            category: .deletion,
            level: .error,
            message: "Permanent deletion failed",
            module: "trash-bins",
            path: "/Users/example/.Trash/stuck.cache",
            action: "delete",
            errorMessage: "The file is in use"
        )
    ])
        .frame(width: 850, height: 620)
}
#endif
