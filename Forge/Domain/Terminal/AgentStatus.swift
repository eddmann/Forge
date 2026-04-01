import SwiftUI

enum AgentStatus: String {
    case idle
    case running
    case waitingForInput = "waiting"
}

// MARK: - SwiftUI Status Dot

/// Pulsing green dot for running, static amber dot for waiting, hidden for idle.
struct AgentStatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 6

    @State private var isPulsing = false

    var body: some View {
        switch status {
        case .running:
            Circle()
                .fill(Color.green)
                .frame(width: size, height: size)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
        case .waitingForInput:
            Circle()
                .fill(Color.orange)
                .frame(width: size, height: size)
        case .idle:
            EmptyView()
        }
    }
}
