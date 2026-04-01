import Combine
import Foundation

class AgentStore: ObservableObject {
    static let shared = AgentStore()

    @Published var agents: [AgentConfig] = []

    private init() {
        load()
        detectAvailability()
    }

    private static let defaultReviewCommands: [String: String] = [
        "claude": "claude --dangerously-skip-permissions \"Apply the code review found at $REVIEW_FILE\"",
        "codex": "codex --yolo \"Apply the code review found at $REVIEW_FILE\"",
        "gemini": "gemini \"Apply the code review found at $REVIEW_FILE\"",
        "amp": "amp \"Apply the code review found at $REVIEW_FILE\"",
        "pi": "pi \"Apply the code review found at $REVIEW_FILE\"",
        "opencode": "opencode --yolo \"Apply the code review found at $REVIEW_FILE\""
    ]

    private func load() {
        var decoded = ForgeStore.shared.loadAgents()
        guard !decoded.isEmpty else {
            seedDefaults()
            return
        }

        var didMigrate = false
        for i in decoded.indices {
            if let defaultCmd = Self.defaultReviewCommands[decoded[i].command],
               decoded[i].reviewCommand != defaultCmd
            {
                decoded[i].reviewCommand = defaultCmd
                didMigrate = true
            }
        }

        agents = decoded
        if didMigrate {
            save()
        }
    }

    private func save() {
        ForgeStore.shared.saveAgents(agents)
    }

    private func seedDefaults() {
        agents = [
            AgentConfig(name: "Claude Code", command: "claude", args: ["--dangerously-skip-permissions"],
                        reviewCommand: "claude --dangerously-skip-permissions \"Apply the code review found at $REVIEW_FILE\""),
            AgentConfig(name: "Codex", command: "codex", args: ["--yolo"],
                        reviewCommand: "codex --yolo \"Apply the code review found at $REVIEW_FILE\""),
            AgentConfig(name: "Gemini CLI", command: "gemini", args: [],
                        reviewCommand: "gemini \"Apply the code review found at $REVIEW_FILE\""),
            AgentConfig(name: "Amp", command: "amp", args: [],
                        reviewCommand: "amp \"Apply the code review found at $REVIEW_FILE\""),
            AgentConfig(name: "Pi", command: "pi", args: [],
                        reviewCommand: "pi \"Apply the code review found at $REVIEW_FILE\""),
            AgentConfig(name: "OpenCode", command: "opencode", args: ["--yolo"],
                        reviewCommand: "opencode --yolo \"Apply the code review found at $REVIEW_FILE\"")
        ]
        save()
    }

    func detectAvailability() {
        for i in agents.indices {
            agents[i].isInstalled = isCommandAvailable(agents[i].command)
        }
    }

    private func isCommandAvailable(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.environment = ["PATH": ShellEnvironment.resolvedPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func addAgent(_ agent: AgentConfig) {
        var newAgent = agent
        newAgent.isInstalled = isCommandAvailable(newAgent.command)
        agents.append(newAgent)
        save()
    }

    func updateAgent(_ agent: AgentConfig) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        var updated = agent
        updated.isInstalled = isCommandAvailable(updated.command)
        agents[index] = updated
        save()
    }

    func deleteAgent(id: UUID) {
        agents.removeAll { $0.id == id }
        save()
    }
}
