import Foundation

struct TerminalSession: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var workingDirectory: String
    var isRunning: Bool
    var launchCommand: String?
    var closeOnExit: Bool
    var agentSessionID: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, workingDirectory, launchCommand, closeOnExit, agentSessionID
    }

    init(id: UUID = UUID(), title: String = "Shell", workingDirectory: String, isRunning: Bool = true, launchCommand: String? = nil, closeOnExit: Bool = false, agentSessionID: String? = nil) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.isRunning = isRunning
        self.launchCommand = launchCommand
        self.closeOnExit = closeOnExit
        self.agentSessionID = agentSessionID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Shell"
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        isRunning = false
        launchCommand = try container.decodeIfPresent(String.self, forKey: .launchCommand)
        closeOnExit = try container.decodeIfPresent(Bool.self, forKey: .closeOnExit) ?? false
        agentSessionID = try container.decodeIfPresent(String.self, forKey: .agentSessionID)
    }
}
