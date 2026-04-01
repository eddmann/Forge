import Foundation

extension Notification.Name {
    static let agentDetectionChanged = Notification.Name("agentDetectionChanged")
}

/// Observes terminal signals (Ghostty action callbacks) and synthesizes agent state.
/// Replaces the old AgentDetector with richer state derived from title, progress, and notifications.
@MainActor
class TerminalObserver {
    static let shared = TerminalObserver()

    struct TerminalSignals {
        var agent: String?
        var titleAnimating: Bool = false
        var titleStatusWord: String?
        var progressActive: Bool = false
        var lastNotificationBody: String?
        var pwd: String?
    }

    private var signalsBySession: [UUID: TerminalSignals] = [:]

    private static let brailleSpinnerChars: Set<Character> = [
        "\u{2802}", "\u{2810}",  // Claude: ⠂ ⠐
        "\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}",  // Codex braille
        "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}",
        "\u{2807}", "\u{280F}"
    ]

    private static let shellPatterns: [String] = ["zsh", "bash", "fish", "sh"]

    private init() {}

    // MARK: - Ghostty Action Handlers

    func handleTitle(sessionID: UUID, title: String) {
        AgentEventLogger.shared.log(source: "terminal", session: sessionID, agent: signalsBySession[sessionID]?.agent, event: "title", data: ["title": title])
        var signals = signalsBySession[sessionID] ?? TerminalSignals()
        let previousAgent = signals.agent

        // Detect agent from title
        let agents = AgentStore.shared.agents
        let firstWord = title.split(separator: " ").first.map(String.init) ?? title

        if agents.contains(where: { $0.command == firstWord }) {
            signals.agent = firstWord
        } else if let agent = agents.first(where: { title.contains($0.name) }) {
            signals.agent = agent.command
        } else if signals.agent != nil {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            let looksLikeShell = (trimmed.contains("@") && trimmed.contains(":"))
                || Self.shellPatterns.contains(trimmed)
                || trimmed.isEmpty
            if looksLikeShell { signals.agent = nil }
        }

        // Detect animation (braille spinner prefix)
        signals.titleAnimating = title.first.map { Self.brailleSpinnerChars.contains($0) } ?? false

        // Parse status word for Codex enriched titles ("⠋ Working | myproject")
        if let pipeIndex = title.firstIndex(of: "|") {
            let beforePipe = title[title.startIndex..<pipeIndex]
                .trimmingCharacters(in: .whitespaces)
            // Remove spinner char if present
            let words = beforePipe.split(separator: " ")
            if words.count >= 1 {
                let candidate = String(words.last!)
                if ["Ready", "Working", "Thinking", "Waiting", "Starting", "Undoing"].contains(candidate) {
                    signals.titleStatusWord = candidate
                }
            }
        } else {
            signals.titleStatusWord = nil
        }

        signalsBySession[sessionID] = signals

        if signals.agent != previousAgent {
            NotificationCenter.default.post(name: .agentDetectionChanged, object: nil)
        }

        publishState(sessionID: sessionID)
    }

    func handleProgress(sessionID: UUID, state: UInt32, progress: Int8) {
        AgentEventLogger.shared.log(source: "terminal", session: sessionID, agent: signalsBySession[sessionID]?.agent, event: "progress", data: ["state": state, "progress": progress])
        var signals = signalsBySession[sessionID] ?? TerminalSignals()
        // GHOSTTY_PROGRESS_STATE_INDETERMINATE = 3, REMOVE = 0
        signals.progressActive = (state == 3)
        signalsBySession[sessionID] = signals
        publishState(sessionID: sessionID)
    }

    func handleNotification(sessionID: UUID, title: String, body: String) {
        AgentEventLogger.shared.log(source: "terminal", session: sessionID, agent: signalsBySession[sessionID]?.agent, event: "notification", data: ["title": title, "body": body])
        var signals = signalsBySession[sessionID] ?? TerminalSignals()
        signals.lastNotificationBody = body
        signalsBySession[sessionID] = signals
        publishState(sessionID: sessionID)
    }

    func handlePwd(sessionID: UUID, pwd: String) {
        var signals = signalsBySession[sessionID] ?? TerminalSignals()
        signals.pwd = pwd
        signalsBySession[sessionID] = signals
    }

    func handleChildExited(sessionID: UUID) {
        signalsBySession.removeValue(forKey: sessionID)
        // Find tab for this session and update store
        if let tab = TerminalSessionManager.shared.tabs.first(where: {
            $0.paneManager?.allSessionIDs.contains(sessionID) == true || $0.sessionIDs.contains(sessionID)
        }) {
            AgentEventStore.shared.updateFromTerminalSignals(tabID: tab.id, agent: nil, activity: .complete)
        }
    }

    // MARK: - Queries

    func detectAgent(sessionID: UUID) -> String? {
        signalsBySession[sessionID]?.agent
    }

    func removeSession(_ sessionID: UUID) {
        signalsBySession.removeValue(forKey: sessionID)
    }

    // MARK: - Private

    private func publishState(sessionID: UUID) {
        guard let signals = signalsBySession[sessionID] else { return }
        guard let tab = TerminalSessionManager.shared.tabs.first(where: {
            $0.paneManager?.allSessionIDs.contains(sessionID) == true || $0.sessionIDs.contains(sessionID)
        }) else { return }

        let activity = synthesizeActivity(signals)
        AgentEventStore.shared.updateFromTerminalSignals(tabID: tab.id, agent: signals.agent, activity: activity)
    }

    private func synthesizeActivity(_ signals: TerminalSignals) -> AgentActivity {
        guard signals.agent != nil else { return .idle }

        // Codex: use status word from enriched title if available
        if let word = signals.titleStatusWord {
            switch word {
            case "Ready": return .idle
            case "Working": return .toolExecuting
            case "Thinking": return .thinking
            case "Waiting": return .waitingForPermission
            case "Starting": return .thinking
            case "Undoing": return .toolExecuting
            default: break
            }
        }

        // Claude: 2x2 matrix (titleAnimating x progressActive)
        switch (signals.titleAnimating, signals.progressActive) {
        case (true, true): return .toolExecuting
        case (true, false): return .thinking
        case (false, true): return .waitingForPermission
        case (false, false): return .idle
        }
    }
}
