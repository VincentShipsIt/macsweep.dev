import SwiftUI
import UniformTypeIdentifiers

/// Secure file deletion view
struct ShredderView: View {
    @EnvironmentObject var appState: AppState
    @State private var droppedFiles: [URL] = []
    @State private var shredLevel: SecureDelete.ShredLevel = .standard
    @State private var isShredding = false
    @State private var progress: Double = 0
    @State private var currentFile: String = ""
    @State private var showingConfirmation = false
    @State private var lastResult: ShredResult?
    @State private var showingResult = false
    @State private var isTargeted = false

    var body: some View {
        FeaturePageShell(
            title: "Shredder",
            subtitle: "Securely delete files beyond recovery.",
            trailing: AnyView(
                Button {
                    selectFiles()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .glassButton()
                .controlSize(.small)
            )
        ) {
            ScrollView {
                VStack(spacing: 24) {
                    // Drop zone
                    dropZone
                        .padding(.horizontal)

                    if !droppedFiles.isEmpty {
                        // File list
                        fileList
                            .padding(.horizontal)

                        // Shred level picker
                        levelPicker
                            .padding(.horizontal)

                        // Shred button
                        shredButton
                            .padding()
                    }

                    // Info section
                    infoSection
                        .padding(.horizontal)

                    Spacer(minLength: 40)
                }
                .padding(.top)
            }
        }
        .sheet(isPresented: $showingResult) {
            resultSheet
        }
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .foregroundStyle(isTargeted ? .red : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.red.opacity(0.1) : Color.clear)
                )

            VStack(spacing: 16) {
                Image(systemName: "scissors")
                    .font(.system(size: 48))
                    .foregroundStyle(isTargeted ? .red : .secondary)

                Text("Drop files here to shred")
                    .font(.headline)
                    .foregroundStyle(isTargeted ? .red : .secondary)

                Text("or click to browse")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(40)
        }
        .frame(height: 200)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .onTapGesture {
            selectFiles()
        }
    }

    // MARK: - File List

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Files to Shred")
                    .font(.headline)

                Spacer()

                Text("\(droppedFiles.count) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear") {
                    droppedFiles.removeAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            ForEach(droppedFiles, id: \.self) { url in
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .lineLimit(1)

                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    Spacer()

                    Button {
                        droppedFiles.removeAll { $0 == url }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Level Picker

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security Level")
                .font(.headline)

            ForEach(SecureDelete.ShredLevel.allCases) { level in
                Button {
                    shredLevel = level
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: shredLevel == level ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(shredLevel == level ? .red : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(level.rawValue)
                                    .font(.headline)

                                Text("(\(level.passes) passes)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(level.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(shredLevel == level ? Color.red.opacity(0.1) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(shredLevel == level ? Color.red : Color.gray.opacity(0.2))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shred Button

    private var shredButton: some View {
        VStack(spacing: 12) {
            if isShredding {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    Text("Shredding: \(currentFile)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    showingConfirmation = true
                } label: {
                    Label("Shred Files", systemImage: "scissors")
                        .frame(maxWidth: .infinity)
                }
                .glassButton(prominent: true)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .confirmationDialog(
            "Shred \(droppedFiles.count) Files?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Shred Permanently", role: .destructive) {
                Task {
                    await shredFiles()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently destroy these files using \(shredLevel.passes) overwrite passes. This cannot be undone.")
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About Secure Deletion")
                .font(.headline)

            Text("""
            Regular deletion only unlinks the file, leaving its bytes recoverable until \
            something else overwrites them. The Shredder overwrites file contents with random \
            data before deleting. Note: on SSD and APFS volumes — every modern Mac — wear-levelling \
            and copy-on-write mean overwriting can't guarantee the original blocks are erased. \
            Keep FileVault on for a real guarantee that deleted data stays unreadable.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                InfoBadge(icon: "exclamationmark.triangle", text: "Cannot be undone", color: .orange)
                InfoBadge(icon: "clock", text: "Slower than normal delete", color: .blue)
                InfoBadge(icon: "lock.shield", text: "Use FileVault for guarantees", color: .green)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Result Sheet

    private var resultSheet: some View {
        VStack(spacing: 20) {
            if let result = lastResult {
                Image(systemName: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(result.success ? .green : .orange)

                Text(result.success ? "Shredding Complete" : "Shredding Completed with Errors")
                    .font(.headline)

                VStack(spacing: 8) {
                    Text("\(result.filesShredded) files shredded")
                    Text("\(result.formattedBytes) destroyed")
                        .foregroundStyle(.secondary)

                    if !result.errors.isEmpty {
                        Text("\(result.errors.count) errors occurred")
                            .foregroundStyle(.orange)
                    }
                }

                Button("Done") {
                    showingResult = false
                    droppedFiles.removeAll()
                }
                .glassButton(prominent: true)
            }
        }
        .padding(40)
        .frame(minWidth: 300)
    }

    // MARK: - Actions

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true

        if panel.runModal() == .OK {
            droppedFiles.append(contentsOf: panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            if !droppedFiles.contains(url) {
                                droppedFiles.append(url)
                            }
                        }
                    }
                }
            }
        }
    }

    private func shredFiles() async {
        isShredding = true
        progress = 0

        var totalFiles = 0
        var totalBytes: Int64 = 0
        var errors: [ShredError] = []

        let fileCount = droppedFiles.count
        let safety = SafetyChecker()

        for (index, url) in droppedFiles.enumerated() {
            await MainActor.run {
                currentFile = url.lastPathComponent
            }

            // Blocklist gate: refuse symlinks, the home/root dirs, whole user
            // folders, and system / app-data / credential roots before any
            // destructive write. Arbitrary user-selected files pass.
            let verdict = safety.validateForShred(url)
            guard verdict.isSafe else {
                errors.append(.unknown("Skipped \(url.lastPathComponent): \(verdict.reason ?? "blocked by safety checks")"))
                continue
            }

            do {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

                if isDirectory.boolValue {
                    let result = try await SecureDelete.shredDirectory(at: url, level: shredLevel) { name, fileProgress in
                        Task { @MainActor in
                            currentFile = name
                            progress = (Double(index) + fileProgress) / Double(fileCount)
                        }
                    }
                    totalFiles += result.filesShredded
                    totalBytes += result.bytesShredded
                    errors.append(contentsOf: result.errors)
                } else {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    try await SecureDelete.shred(file: url, level: shredLevel) { fileProgress in
                        Task { @MainActor in
                            progress = (Double(index) + fileProgress) / Double(fileCount)
                        }
                    }
                    totalFiles += 1
                    totalBytes += size
                }
            } catch let error as ShredError {
                errors.append(error)
            } catch {
                errors.append(.unknown(error.localizedDescription))
            }
        }

        await MainActor.run {
            isShredding = false
            lastResult = ShredResult(filesShredded: totalFiles, bytesShredded: totalBytes, errors: errors)
            showingResult = true
        }
    }
}

// MARK: - Info Badge

struct InfoBadge: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(color)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    ShredderView()
        .environmentObject(AppState())
        .frame(width: 600, height: 700)
}

#endif
