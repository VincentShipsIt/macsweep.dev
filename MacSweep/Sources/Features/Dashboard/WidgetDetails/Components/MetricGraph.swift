import SwiftUI

/// Real-time line graph with threshold indicators
struct MetricGraph: View {
    let data: [Double]
    var maxValue: Double = 100
    var warningThreshold: Double? = nil
    var criticalThreshold: Double? = nil
    var color: Color = .blue
    var showGrid: Bool = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background grid
                if showGrid {
                    gridLines(in: geometry.size)
                }

                // Threshold lines
                if let warning = warningThreshold {
                    thresholdLine(value: warning, in: geometry.size, color: .orange)
                }
                if let critical = criticalThreshold {
                    thresholdLine(value: critical, in: geometry.size, color: .red)
                }

                // Gradient fill under the line
                if data.count > 1 {
                    linearGradientFill(in: geometry.size)
                }

                // Data line
                if data.count > 1 {
                    dataLine(in: geometry.size)
                }
            }
        }
    }

    private func gridLines(in size: CGSize) -> some View {
        Path { path in
            // Horizontal lines (4 divisions)
            for i in 0...4 {
                let y = CGFloat(i) / 4.0 * size.height
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            // Vertical lines (time divisions)
            let verticalDivisions = 6
            for i in 0...verticalDivisions {
                let x = CGFloat(i) / CGFloat(verticalDivisions) * size.width
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
    }

    private func thresholdLine(value: Double, in size: CGSize, color: Color) -> some View {
        let y = size.height - (CGFloat(value / maxValue) * size.height)
        return Path { path in
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
    }

    private func dataLine(in size: CGSize) -> some View {
        Path { path in
            let stepX = size.width / CGFloat(max(data.count - 1, 1))

            for (index, value) in data.enumerated() {
                let x = CGFloat(index) * stepX
                let normalizedValue = min(value / maxValue, 1.0)
                let y = size.height - (CGFloat(normalizedValue) * size.height)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(
            LinearGradient(
                colors: [color.opacity(0.6), color],
                startPoint: .leading,
                endPoint: .trailing
            ),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        )
    }

    private func linearGradientFill(in size: CGSize) -> some View {
        Path { path in
            let stepX = size.width / CGFloat(max(data.count - 1, 1))

            // Start at bottom left
            path.move(to: CGPoint(x: 0, y: size.height))

            // Draw the data line
            for (index, value) in data.enumerated() {
                let x = CGFloat(index) * stepX
                let normalizedValue = min(value / maxValue, 1.0)
                let y = size.height - (CGFloat(normalizedValue) * size.height)
                path.addLine(to: CGPoint(x: x, y: y))
            }

            // Close the path at bottom right
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
        .fill(
            LinearGradient(
                colors: [color.opacity(0.3), color.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// Dual-line graph for network traffic (download + upload)
struct DualLineGraph: View {
    let downloadData: [UInt64]
    let uploadData: [UInt64]
    var downloadColor: Color = .green
    var uploadColor: Color = .blue

    private var maxValue: UInt64 {
        let maxDownload = downloadData.max() ?? 1
        let maxUpload = uploadData.max() ?? 1
        return max(maxDownload, maxUpload, 1024) // Minimum 1 KB/s scale
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Grid
                gridLines(in: geometry.size)

                // Download line
                dataLine(data: downloadData, in: geometry.size, color: downloadColor)

                // Upload line
                dataLine(data: uploadData, in: geometry.size, color: uploadColor)
            }
        }
    }

    private func gridLines(in size: CGSize) -> some View {
        Path { path in
            for i in 0...4 {
                let y = CGFloat(i) / 4.0 * size.height
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)
    }

    private func dataLine(data: [UInt64], in size: CGSize, color: Color) -> some View {
        Path { path in
            guard data.count > 1 else { return }
            let stepX = size.width / CGFloat(max(data.count - 1, 1))

            for (index, value) in data.enumerated() {
                let x = CGFloat(index) * stepX
                let normalizedValue = min(Double(value) / Double(maxValue), 1.0)
                let y = size.height - (CGFloat(normalizedValue) * size.height)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

/// Alert level for color coding
enum MetricAlertLevel {
    case normal
    case warning
    case critical

    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

/// Helper for determining alert levels
struct MetricThresholds {
    static func cpu(usage: Double, temperature: Double?) -> MetricAlertLevel {
        let temp = temperature ?? 0
        if usage >= 90 || temp > 80 { return .critical }
        if usage >= 70 || temp > 60 { return .warning }
        return .normal
    }

    static func memory(usagePercent: Double) -> MetricAlertLevel {
        if usagePercent >= 0.90 { return .critical }
        if usagePercent >= 0.75 { return .warning }
        return .normal
    }

    static func storage(freePercent: Double) -> MetricAlertLevel {
        if freePercent < 0.10 { return .critical }
        if freePercent < 0.20 { return .warning }
        return .normal
    }

    static func battery(percent: Int, isCharging: Bool, hasBattery: Bool = true) -> MetricAlertLevel {
        guard hasBattery else { return .normal }
        if isCharging { return .normal }
        if percent < 20 { return .critical }
        if percent < 50 { return .warning }
        return .normal
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VStack(spacing: 20) {
        MetricGraph(
            data: [20, 35, 45, 30, 60, 75, 50, 40, 55, 65, 80, 70],
            warningThreshold: 70,
            criticalThreshold: 90,
            color: .orange
        )
        .frame(height: 100)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

        DualLineGraph(
            downloadData: [1024, 2048, 1536, 4096, 3072, 2560],
            uploadData: [512, 768, 1024, 512, 1280, 1024]
        )
        .frame(height: 80)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    .padding()
}

#endif
