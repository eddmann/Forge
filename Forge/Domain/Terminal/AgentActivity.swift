import SwiftUI

enum AgentActivity: String, Codable {
    case idle
    case thinking
    case toolExecuting
    case waitingForPermission
    case waitingForInput
    case retrying
    case compacting
    case complete
}

struct ToolExecution {
    let name: String
    let input: [String: Any]?
    let startedAt: Date
}

struct AgentSessionState {
    var agent: String
    var activity: AgentActivity = .idle
    var currentTool: ToolExecution?
    var lastPrompt: String?
    var lastResponse: String?
    var model: String?
    var cwd: String?
    var agentSessionID: String?
    var transcriptPath: String?
    var permissionDetail: String?
}

// MARK: - SwiftUI Status Dot

struct AgentStatusDot: View {
    let activity: AgentActivity
    var size: CGFloat = 6

    @State private var isSpinning = false

    var body: some View {
        switch activity {
        case .thinking:
            SpinningArc(color: .blue, size: size, isSpinning: $isSpinning)
        case .toolExecuting:
            SpinningArc(color: .green, size: size, isSpinning: $isSpinning)
        case .waitingForPermission, .waitingForInput:
            Circle()
                .fill(Color.orange)
                .frame(width: size, height: size)
        case .retrying:
            SpinningArc(color: .red, size: size, isSpinning: $isSpinning)
        case .compacting:
            SpinningArc(color: .purple, size: size, isSpinning: $isSpinning)
        case .idle, .complete:
            EmptyView()
        }
    }
}

private struct SpinningArc: View {
    let color: Color
    let size: CGFloat
    @Binding var isSpinning: Bool

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.65)
            .stroke(color, style: StrokeStyle(lineWidth: size * 0.3, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear { isSpinning = true }
    }
}
