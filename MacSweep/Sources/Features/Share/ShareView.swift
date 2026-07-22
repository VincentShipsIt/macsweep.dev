import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShareView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var statusMessage: String?
    @State private var statusResetTask: Task<Void, Never>?

    private let windowDays = 30

    private var summary: CleanupPerformanceSummary {
        CleanupPerformanceSummary(entries: appState.cleanupPerformanceHistory, windowDays: windowDays)
    }

    private var canExport: Bool {
        !summary.isEmpty
    }

    var body: some View {
        FeaturePageShell(
            title: "Share",
            subtitle: "Social card export"
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    cardPreview

                    actionRow

                    tweetTextPanel
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .macSweepListSurface()
        }
    }

    private var cardPreview: some View {
        Color.clear
        .aspectRatio(CleanupShareCardLayout.aspectRatio, contentMode: .fit)
        .frame(maxWidth: CleanupShareCardLayout.width)
        .overlay(alignment: .topLeading) {
            GeometryReader { proxy in
                let availableWidth = max(1, proxy.size.width - 2)
                let scale = min(1, max(0.34, availableWidth / CleanupShareCardLayout.width))

                CleanupPerformanceShareCard(summary: summary, diskUsage: appState.diskUsage)
                    .frame(width: CleanupShareCardLayout.width, height: CleanupShareCardLayout.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(
                        width: CleanupShareCardLayout.width * scale,
                        height: CleanupShareCardLayout.height * scale,
                        alignment: .topLeading
                    )
                    .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                copyPNG()
            } label: {
                Label("Copy PNG", systemImage: "doc.on.doc")
            }
            .glassButton(prominent: true)
            .disabled(!canExport)

            Button {
                savePNG()
            } label: {
                Label("Save PNG", systemImage: "square.and.arrow.down")
            }
            .glassButton()
            .disabled(!canExport)

            Button {
                copyTweetText()
            } label: {
                Label("Copy Text", systemImage: "quote.bubble")
            }
            .glassButton()
            .disabled(!canExport)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
    }

    private var tweetTextPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tweet Text")
                .font(.headline)

            Text(tweetText)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(canExport ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .macSweepCard()
    }

    private var tweetText: String {
        let productName = MacSweepVersion.productName
        guard !summary.isEmpty else {
            return "Run a \(productName) cleanup to generate a cleanup receipt."
        }

        let cleaned = numberFormatter.string(from: NSNumber(value: summary.totalItemsProcessed)) ?? "\(summary.totalItemsProcessed)"
        let success = summary.successRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "--"
        let receiptTitle = "\(productName) cleanup receipt"

        return """
        \(receiptTitle): \(formattedBytes(summary.totalBytesFreed)) reclaimed in the last \(windowDays) days.
        Cleanups: \(summary.cleanupCount). Items cleaned: \(cleaned). Success rate: \(success).
        Install: brew install --cask vincentshipsit/tap/macsweep
        """
    }

    /// Shows a transient status caption, animating it in and clearing it after a
    /// short delay so the `.transition(.opacity)` on the caption actually fires.
    @MainActor
    private func showStatus(_ message: String) {
        // Snapshot the flag now; `@Environment` is only reliable during body
        // evaluation, and the reset runs later inside an escaping Task.
        let animates = !reduceMotion
        statusResetTask?.cancel()
        withAnimation(animates ? .easeInOut(duration: 0.2) : nil) {
            statusMessage = message
        }
        statusResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(animates ? .easeInOut(duration: 0.2) : nil) {
                statusMessage = nil
            }
        }
    }

    @MainActor
    private func copyPNG() {
        guard let data = renderedPNGData() else {
            showStatus("Could not render PNG.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        showStatus("PNG copied.")
    }

    @MainActor
    private func savePNG() {
        guard let data = renderedPNGData() else {
            showStatus("Could not render PNG.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "macsweep-cleanup-receipt.png"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            showStatus("PNG saved.")
        } catch {
            showStatus("Could not save PNG.")
        }
    }

    @MainActor
    private func copyTweetText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tweetText, forType: .string)
        showStatus("Text copied.")
    }

    @MainActor
    private func renderedPNGData() -> Data? {
        let card = CleanupPerformanceShareCard(summary: summary, diskUsage: appState.diskUsage)
            .frame(width: CleanupShareCardLayout.width, height: CleanupShareCardLayout.height)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2

        guard let image = renderer.nsImage else { return nil }
        return image.pngData
    }
}

private enum CleanupShareCardLayout {
    static let width: CGFloat = 1200
    static let height: CGFloat = 675
    static let aspectRatio = width / height
}

private struct CleanupPerformanceShareCard: View {
    let summary: CleanupPerformanceSummary
    let diskUsage: DiskUsage?

    private var bars: [CleanupPerformanceEntry] {
        summary.recentChartEntries
    }

    private var maxBarBytes: Int64 {
        max(bars.map(\.bytesFreed).max() ?? 0, 1)
    }

    var body: some View {
        ZStack {
            CleanupShareCardBackground()

            VStack(alignment: .leading, spacing: 0) {
                header

                Spacer(minLength: 36)

                HStack(alignment: .bottom, spacing: 56) {
                    heroStats

                    Spacer(minLength: 24)

                    chartPanel
                }

                Spacer(minLength: 34)

                footer
            }
            .padding(.horizontal, 54)
            .padding(.vertical, 42)
        }
        .frame(width: CleanupShareCardLayout.width, height: CleanupShareCardLayout.height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                MacSweepTheme.accent.opacity(0.95),
                                MacSweepTheme.accentBlue.opacity(0.95),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.82))
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text("MacSweep")
                    .font(.system(size: 29, weight: .heavy))
                    .foregroundStyle(.white)

                Text("local cleanup performance for macOS")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer()

            Text("CLEANUP RECEIPT")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.10), in: Capsule())
        }
    }

    private var heroStats: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.isEmpty ? "Ready" : formattedBytes(summary.totalBytesFreed))
                    .font(.system(size: 82, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Text(summary.isEmpty ? "RUN A CLEANUP TO MINT YOUR RECEIPT" : "RECLAIMED IN 30 DAYS")
                    .font(.system(size: 15, weight: .heavy, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(MacSweepTheme.accent)
            }

            HStack(spacing: 10) {
                CleanupShareStatPill(title: "CLEANUPS", value: summary.isEmpty ? "--" : "\(summary.cleanupCount)")
                CleanupShareStatPill(title: "ITEMS", value: summary.isEmpty ? "--" : compactNumber(summary.totalItemsProcessed))
                CleanupShareStatPill(title: "SUCCESS", value: successText)
            }

            Text(detailLine)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(2)
                .frame(width: 560, alignment: .leading)
        }
        .frame(width: 620, alignment: .leading)
    }

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent cleanups")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)

                    Text(summary.isEmpty ? "waiting for history" : "last \(min(bars.count, 12)) receipts")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.48))
                }

                Spacer()

                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(MacSweepTheme.accentBlue)
            }

            HStack(alignment: .bottom, spacing: 9) {
                ForEach(chartBars.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(chartBars[index].color)
                        .frame(width: 13, height: chartBars[index].height)
                }
            }
            .frame(height: 138, alignment: .bottom)

            Divider()
                .overlay(Color.white.opacity(0.10))

            HStack {
                CleanupShareMetric(label: "Best", value: bestText)
                Spacer()
                CleanupShareMetric(label: "Free now", value: diskUsage?.formattedFree ?? "--")
            }
        }
        .padding(22)
        .frame(width: 340)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            CleanupShareFooterPill(
                icon: "globe",
                text: MacSweepLinks.websiteDisplayName
            )
            CleanupShareFooterPill(icon: "terminal", text: "brew install --cask vincentshipsit/tap/macsweep")
        }
    }

    private var detailLine: String {
        guard !summary.isEmpty else {
            return "MacSweep tracks local cleanup wins after you clean selected items."
        }

        if let last = summary.lastCleanup {
            return "Latest cleanup freed \(formattedBytes(last.bytesFreed)) across \(last.itemsProcessed) items."
        }

        return "Cleanup history is tracked locally on this Mac."
    }

    private var successText: String {
        guard let successRate = summary.successRate, !summary.isEmpty else { return "--" }
        return "\(Int((successRate * 100).rounded()))%"
    }

    private var bestText: String {
        guard let best = summary.bestCleanup else { return "--" }
        return formattedBytes(best.bytesFreed)
    }

    private var chartBars: [(height: CGFloat, color: Color)] {
        if summary.isEmpty {
            return [28, 46, 34, 72, 50, 96, 42, 60, 36, 30, 26, 22].map {
                (CGFloat($0), Color.white.opacity(0.18))
            }
        }

        return bars.map { entry in
            let ratio = Double(entry.bytesFreed) / Double(maxBarBytes)
            let height = CGFloat(22 + ratio * 116)
            let color = entry.errorCount == 0 ? MacSweepTheme.accent : Color.orange.opacity(0.92)
            return (height, color)
        }
    }
}

private struct CleanupShareCardBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.018, green: 0.021, blue: 0.020)

            LinearGradient(
                colors: [
                    MacSweepTheme.accent.opacity(0.18),
                    Color.clear,
                    MacSweepTheme.accentBlue.opacity(0.11),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            grid
        }
    }

    private var grid: some View {
        ZStack {
            ForEach(0..<25, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(index.isMultiple(of: 4) ? 0.055 : 0.028))
                    .frame(width: 1)
                    .offset(x: CGFloat(index) * 50 - 600)
            }

            ForEach(0..<15, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(index.isMultiple(of: 4) ? 0.055 : 0.028))
                    .frame(height: 1)
                    .offset(y: CGFloat(index) * 50 - 350)
            }
        }
    }
}

private struct CleanupShareStatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.48))

            Text(value)
                .font(.system(size: 17, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(minWidth: 106, alignment: .leading)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct CleanupShareMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))

            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }
}

private struct CleanupShareFooterPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(MacSweepTheme.accentBlue)
                .frame(width: 20)

            Text(text)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private let numberFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
}()

private func formattedBytes(_ bytes: Int64) -> String {
    bytes.formattedFileSize
}

private func compactNumber(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }

    if value >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000)
    }

    return "\(value)"
}

private extension NSImage {
    var pngData: Data? {
        guard let tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else { return nil }

        return bitmap.representation(using: .png, properties: [:])
    }
}
