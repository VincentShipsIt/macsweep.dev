import SwiftUI

struct QuickActionCard: View {
    let title: String
    let icon: String
    let color: Color
    let isLoading: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task {
                await action()
            }
        } label: {
            VStack(spacing: 12) {
                if isLoading {
                    ProgressView()
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: icon)
                        .font(.title)
                        .foregroundStyle(color)
                }

                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .macSweepCard(radius: 12)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}
