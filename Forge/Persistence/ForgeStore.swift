import Foundation

// MARK: - Serialization Types (config.json)

private struct ConfigFile: Codable {
    var agents: [AgentConfig] = []
    var terminal: TerminalAppearanceConfig = .init()
}

// MARK: - Serialization Types (projects.json)

private struct ProjectFile: Codable {
    var projects: [ProjectEntry] = []
}

private struct ProjectEntry: Codable {
    var id: UUID
    var name: String
    var path: String
    var defaultBranch: String
    var createdAt: Date
    var lastActiveAt: Date?
    var workspaces: [WorkspaceEntry]

    init(project: Project, workspaces: [Workspace]) {
        id = project.id
        name = project.name
        path = project.path
        defaultBranch = project.defaultBranch
        createdAt = project.createdAt
        lastActiveAt = project.lastActiveAt
        self.workspaces = workspaces.map { WorkspaceEntry(workspace: $0) }
    }

    func toProject() -> Project {
        Project(
            id: id,
            name: name,
            path: path,
            defaultBranch: defaultBranch,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }

    func toWorkspaces() -> [Workspace] {
        workspaces.map { $0.toWorkspace(projectID: id) }
    }
}

private struct WorkspaceEntry: Codable {
    var id: UUID
    var name: String
    var path: String
    var branch: String
    var parentBranch: String
    var status: Workspace.Status
    var fullClone: Bool
    var createdAt: Date

    init(workspace: Workspace) {
        id = workspace.id
        name = workspace.name
        path = workspace.path
        branch = workspace.branch
        parentBranch = workspace.parentBranch
        status = workspace.status
        fullClone = workspace.fullClone
        createdAt = workspace.createdAt
    }

    func toWorkspace(projectID: UUID) -> Workspace {
        Workspace(
            id: id,
            projectID: projectID,
            name: name,
            path: path,
            branch: branch,
            parentBranch: parentBranch,
            status: status,
            fullClone: fullClone,
            createdAt: createdAt
        )
    }
}

// MARK: - Serialization Types (state/sessions.json)

struct SessionStateFile: Codable {
    var activeProjectID: UUID?
    var activeWorkspaceID: UUID?
    var diffViewMode: String = "Unified"
    var collapsedProjects: Set<UUID> = []
    var hooksDeclined: Bool = false
    var workspaceSummariesEnabled: Bool = true
    var summarizerCommand: String = "claude -p --model haiku"
    var restoreScrollback: Bool = false
    var summaries: [String: String] = [:]
    var scopes: [String: ScopeState] = [:]
    var scrollback: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeProjectID = try c.decodeIfPresent(UUID.self, forKey: .activeProjectID)
        activeWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
        diffViewMode = try c.decodeIfPresent(String.self, forKey: .diffViewMode) ?? "Unified"
        collapsedProjects = try c.decodeIfPresent(Set<UUID>.self, forKey: .collapsedProjects) ?? []
        hooksDeclined = try c.decodeIfPresent(Bool.self, forKey: .hooksDeclined) ?? false
        workspaceSummariesEnabled = try c.decodeIfPresent(Bool.self, forKey: .workspaceSummariesEnabled) ?? true
        summarizerCommand = try c.decodeIfPresent(String.self, forKey: .summarizerCommand) ?? "claude -p --model haiku"
        restoreScrollback = try c.decodeIfPresent(Bool.self, forKey: .restoreScrollback) ?? false
        summaries = try c.decodeIfPresent([String: String].self, forKey: .summaries) ?? [:]
        scopes = try c.decodeIfPresent([String: ScopeState].self, forKey: .scopes) ?? [:]
        scrollback = try c.decodeIfPresent([String: String].self, forKey: .scrollback) ?? [:]
    }
}

struct ScopeState: Codable {
    var activeTab: UUID?
    var tabs: [TabEntry] = []
}

struct TabEntry: Codable {
    var id: UUID
    var title: String
    var icon: String?
    var kind: TabKind
    var sessions: [SessionEntry]
    var splitLayout: SplitLayoutSnapshot?

    init(tab: TerminalTab, sessions: [TerminalSession], splitLayout: SplitLayoutSnapshot?) {
        id = tab.id
        title = tab.title
        icon = tab.icon
        kind = tab.kind
        self.sessions = sessions.map { SessionEntry(session: $0) }
        self.splitLayout = splitLayout
    }

    func toTab(projectID: UUID?, workspaceID: UUID?) -> TerminalTab {
        TerminalTab(
            id: id,
            projectID: projectID,
            workspaceID: workspaceID,
            sessionID: sessions.first?.id ?? UUID(),
            title: title,
            icon: icon,
            kind: kind
        )
    }

    func toSessions() -> [TerminalSession] {
        sessions.map { $0.toSession() }
    }
}

struct SessionEntry: Codable {
    var id: UUID
    var title: String
    var directory: String
    var command: String?
    var autoClose: Bool
    var agentSessionID: String?

    init(session: TerminalSession) {
        id = session.id
        title = session.title
        directory = session.workingDirectory
        command = session.launchCommand
        autoClose = session.closeOnExit
        agentSessionID = session.agentSessionID
    }

    func toSession() -> TerminalSession {
        TerminalSession(
            id: id,
            title: title,
            workingDirectory: directory,
            isRunning: false,
            launchCommand: command,
            closeOnExit: autoClose,
            agentSessionID: agentSessionID
        )
    }
}

/// Serializable split tree layout for a tab's pane arrangement.
indirect enum SplitLayoutSnapshot: Codable {
    case pane(SplitLayoutPane)
    case split(SplitLayoutSplit)

    struct SplitLayoutPane: Codable {
        var session: String // UUID string of the terminal session
    }

    struct SplitLayoutSplit: Codable {
        var orientation: String // "horizontal" or "vertical"
        var dividerPosition: Double
        var first: SplitLayoutSnapshot
        var second: SplitLayoutSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case type, pane, split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "pane":
            self = try .pane(container.decode(SplitLayoutPane.self, forKey: .pane))
        case "split":
            self = try .split(container.decode(SplitLayoutSplit.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown layout type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case let .split(split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

// MARK: - ForgeStore

final class ForgeStore {
    static let shared = ForgeStore()

    let forgeDir: URL
    let stateDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        forgeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".forge")
        stateDir = forgeDir.appendingPathComponent("state")
        try? FileManager.default.createDirectory(at: forgeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
    }

    // MARK: - Generic JSON Helpers

    private func loadJSON<T: Decodable>(at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func saveJSON(_ value: some Encodable, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private var configURL: URL {
        forgeDir.appendingPathComponent("config.json")
    }

    private var projectsURL: URL {
        forgeDir.appendingPathComponent("projects.json")
    }

    private var sessionsURL: URL {
        stateDir.appendingPathComponent("sessions.json")
    }

    // MARK: - Config (agents + appearance)

    private func loadConfigFile() -> ConfigFile {
        loadJSON(at: configURL) ?? ConfigFile()
    }

    func loadAgents() -> [AgentConfig] {
        loadConfigFile().agents
    }

    func saveAgents(_ agents: [AgentConfig]) {
        var config = loadConfigFile()
        config.agents = agents
        saveJSON(config, to: configURL)
    }

    func loadAppearance() -> TerminalAppearanceConfig? {
        let config = loadConfigFile()
        return config.terminal
    }

    func saveAppearance(_ appearance: TerminalAppearanceConfig) {
        var config = loadConfigFile()
        config.terminal = appearance
        saveJSON(config, to: configURL)
    }

    // MARK: - Projects (projects + workspaces)

    private func loadProjectFile() -> ProjectFile {
        loadJSON(at: projectsURL) ?? ProjectFile()
    }

    func loadProjectData() -> (projects: [Project], workspaces: [Workspace]) {
        let file = loadProjectFile()
        var projects: [Project] = []
        var workspaces: [Workspace] = []
        for entry in file.projects {
            let project = entry.toProject()
            guard FileManager.default.fileExists(atPath: project.path) else { continue }
            projects.append(project)
            for ws in entry.toWorkspaces() {
                if FileManager.default.fileExists(atPath: ws.path) {
                    workspaces.append(ws)
                }
            }
        }
        return (projects, workspaces)
    }

    func saveProjectData(projects: [Project], workspaces: [Workspace]) {
        let entries = projects.map { project in
            ProjectEntry(
                project: project,
                workspaces: workspaces.filter { $0.projectID == project.id }
            )
        }
        saveJSON(ProjectFile(projects: entries), to: projectsURL)
    }

    // MARK: - Session State

    func loadSessionState() -> SessionStateFile? {
        loadJSON(at: sessionsURL)
    }

    func saveSessionState(_ state: SessionStateFile) {
        saveJSON(state, to: sessionsURL)
    }

    /// Convenience: load just the state fields (active selection, prefs, flags)
    func loadStateFields() -> SessionStateFile {
        loadSessionState() ?? SessionStateFile()
    }

    /// Convenience: update just the state fields without touching scopes/scrollback
    func updateStateFields(_ update: (inout SessionStateFile) -> Void) {
        var state = loadStateFields()
        update(&state)
        saveSessionState(state)
    }

    // MARK: - Directories

    var clonesDir: URL {
        let dir = forgeDir.appendingPathComponent("clones")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var reviewsDir: URL {
        let dir = forgeDir.appendingPathComponent("reviews")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
