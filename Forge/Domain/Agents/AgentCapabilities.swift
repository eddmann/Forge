import Foundation

struct MCPServerInfo: Identifiable {
    let id = UUID()
    let name: String
    let commandOrURL: String
    let type: ServerType
    let scope: CapabilityScope

    enum ServerType: String {
        case stdio, sse, http
    }
}

struct AgentSkillInfo: Identifiable {
    let id = UUID()
    let name: String
    let description: String?
    let filePath: String
    let scope: CapabilityScope
}

struct AgentPluginInfo: Identifiable {
    let id = UUID()
    let name: String
    let version: String?
    let enabled: Bool
}

struct AgentInstructions {
    let fileName: String
    let filePath: String
    let exists: Bool
}

enum CapabilityScope: String {
    case user
    case project
}

struct AgentCapabilities: Identifiable {
    let id = UUID()
    let agentName: String
    let icon: String
    let isInstalled: Bool
    var mcpServers: [MCPServerInfo]
    var skills: [AgentSkillInfo]
    var plugins: [AgentPluginInfo]
    var instructions: [AgentInstructions]
}
