import Foundation

extension Notification.Name {
    static let agentDetectionChanged = Notification.Name("agentDetectionChanged")
}

/// Tracks which sessions are currently running AI agents based on
/// Ghostty's SET_TITLE action. Agents are detected when the title
/// contains an agent command name, and cleared when the title looks
/// like a plain shell prompt (user@host or shell name).
@MainActor
class AgentDetector {
    static let shared = AgentDetector()

    /// Maps session UUID → detected agent command name (e.g. "claude", "codex").
    private var agentBySession: [UUID: String] = [:]

    /// Shell patterns that indicate the agent has exited and we're back to a shell.
    private static let shellPatterns: [String] = ["zsh", "bash", "fish", "sh"]

    private init() {}

    /// Called when Ghostty fires SET_TITLE for a surface.
    func handleTitleChange(sessionID: UUID, title: String) {
        let agents = AgentStore.shared.agents
        let agentCommands = Set(agents.map(\.command))
        let previousAgent = agentBySession[sessionID]

        // Check if title exactly starts with an agent command (first word).
        // Handles: "claude", "codex", "pi", "opencode", "claude --flags"
        let firstWord = title.split(separator: " ").first.map(String.init) ?? title
        if agentCommands.contains(firstWord) {
            agentBySession[sessionID] = firstWord
            if previousAgent != firstWord { postChange() }
            return
        }

        // Check if any agent display name appears in the title.
        // Handles: "✳ Claude Code", "π - api-cedar-falcon"
        for agent in agents {
            if title.contains(agent.name) {
                if previousAgent != agent.command {
                    agentBySession[sessionID] = agent.command
                    postChange()
                }
                return
            }
        }

        // If we currently have an agent tracked, only clear when title
        // looks like a shell prompt (user@host:path) meaning agent exited.
        if previousAgent != nil {
            let trimmed = title.trimmingCharacters(in: .whitespaces)
            let looksLikeShell = trimmed.contains("@") && trimmed.contains(":")
                || Self.shellPatterns.contains(trimmed)
                || trimmed.isEmpty
            if looksLikeShell {
                agentBySession.removeValue(forKey: sessionID)
                postChange()
            }
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .agentDetectionChanged, object: nil)
    }

    /// Returns the agent command running in the given session, or nil.
    func detectAgent(sessionID: UUID) -> String? {
        agentBySession[sessionID]
    }

    /// Remove tracking for a closed session.
    func removeSession(_ sessionID: UUID) {
        agentBySession.removeValue(forKey: sessionID)
    }
}
