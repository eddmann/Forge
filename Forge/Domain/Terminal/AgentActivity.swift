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

    @State private var isPulsing = false

    var body: some View {
        switch activity {
        case .thinking:
            Circle()
                .fill(Color.blue)
                .frame(width: size, height: size)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
        case .toolExecuting:
            Circle()
                .fill(Color.green)
                .frame(width: size, height: size)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
        case .waitingForPermission, .waitingForInput:
            Circle()
                .fill(Color.orange)
                .frame(width: size, height: size)
        case .retrying:
            Circle()
                .fill(Color.red)
                .frame(width: size, height: size)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
        case .compacting:
            Circle()
                .fill(Color.purple)
                .frame(width: size, height: size)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }
        case .idle, .complete:
            EmptyView()
        }
    }
}
