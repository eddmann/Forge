import Combine
import Foundation

class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    #if DEBUG
        /// When true, persistence and git operations are skipped.
        var isDemo = false
    #endif

    @Published var projects: [Project] = []
    @Published var workspaces: [Workspace] = []
    @Published var activeProjectID: UUID? {
        didSet { selectionDidChange() }
    }

    @Published var activeWorkspaceID: UUID? {
        didSet { selectionDidChange() }
    }

    @Published var currentBranch: String = ""
    @Published var allBranches: [String] = []
    @Published var availableEditors: [ExternalEditor] = []
    @Published var gitRefreshTrigger: UInt = 0

    func requestGitRefresh() {
        gitRefreshTrigger += 1
    }

    private var saveWorkItem: DispatchWorkItem?
    private var selectionCallbacksEnabled = false
    private let activityThrottleInterval: TimeInterval = 30

    var activeProject: Project? {
        guard let id = activeProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Root path for the current scope (workspace if selected, otherwise project origin).
    var effectiveRootPath: String? {
        activeWorkspace?.path ?? activeProject?.path
    }

    /// Full working directory for the current scope.
    var effectivePath: String? {
        effectiveRootPath
    }

    /// Workspaces belonging to a specific project, sorted by last activity (most recent first).
    func workspaces(for projectID: UUID) -> [Workspace] {
        workspaces
            .filter { $0.projectID == projectID }
            .sorted {
                ($0.lastActiveAt ?? $0.createdAt) > ($1.lastActiveAt ?? $1.createdAt)
            }
    }

    private init() {
        load()
        detectEditors()
        selectionCallbacksEnabled = true
        DispatchQueue.main.async { [weak self] in
            self?.selectionDidChange()
        }
    }

    // MARK: - Persistence

    private func load() {
        let data = ForgeStore.shared.loadProjectData()
        projects = data.projects
        workspaces = data.workspaces
        restoreSelection()
    }

    private func saveAll() {
        ForgeStore.shared.saveProjectData(projects: projects, workspaces: workspaces)
    }

    // MARK: - Activity Tracking

    func recordActivity(for projectID: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let now = Date()
        if let last = projects[idx].lastActiveAt,
           now.timeIntervalSince(last) < activityThrottleInterval
        {
            return
        }
        projects[idx].lastActiveAt = now
        debouncedSave()
    }

    func recordActivity(forWorkspace workspaceID: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let now = Date()
        if let last = workspaces[idx].lastActiveAt,
           now.timeIntervalSince(last) < activityThrottleInterval
        {
            return
        }
        workspaces[idx].lastActiveAt = now
        debouncedSave()
    }

    private func debouncedSave() {
        #if DEBUG
            if isDemo { return }
        #endif
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveAll()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func selectionDidChange() {
        guard selectionCallbacksEnabled else { return }
        #if DEBUG
            if isDemo { return }
        #endif
        ForgeStore.shared.updateStateFields { state in
            state.activeProjectID = self.activeProjectID
            state.activeWorkspaceID = self.activeWorkspaceID
        }
    }

    // MARK: - Editor Detection

    func detectEditors() {
        var editors: [ExternalEditor] = []

        let editorChecks: [(String, String, String)] = [
            ("VS Code", "code", "/usr/local/bin/code"),
            ("Zed", "zed", "/usr/local/bin/zed")
        ]

        for (name, command, fallbackPath) in editorChecks {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [command]
            process.environment = ["PATH": ShellEnvironment.resolvedPath]
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    editors.append(ExternalEditor(name: name, command: command))
                }
            } catch {
                if FileManager.default.fileExists(atPath: fallbackPath) {
                    editors.append(ExternalEditor(name: name, command: command))
                }
            }
        }

        availableEditors = editors
    }

    // MARK: - Project Actions

    func addProject(from url: URL) {
        guard !projects.contains(where: { $0.path == url.path }) else {
            if let existing = projects.first(where: { $0.path == url.path }) {
                activeProjectID = existing.id
                activeWorkspaceID = nil
            }
            return
        }

        let project = Project(url: url)
        projects.append(project)
        activeProjectID = project.id
        activeWorkspaceID = nil
        saveAll()
    }

    func removeProject(id: UUID) {
        // Remove associated workspaces
        let projectWorkspaces = workspaces.filter { $0.projectID == id }
        for ws in projectWorkspaces {
            AgentSetup.shared.untrustCodexProject(path: ws.path)
            try? FileManager.default.removeItem(atPath: ws.path)
        }
        workspaces.removeAll { $0.projectID == id }

        projects.removeAll { $0.id == id }
        ForgeStore.shared.updateStateFields { state in
            state.collapsedProjects.remove(id)
        }

        if activeProjectID == id {
            activeProjectID = projects.first?.id
            activeWorkspaceID = nil
        }
        saveAll()
    }

    // MARK: - Workspace Actions

    func addWorkspace(_ workspace: Workspace) {
        workspaces.append(workspace)
        let wsID = workspace.id
        Task { @MainActor in
            TerminalSessionManager.shared.newlyCreatedWorkspaceIDs.insert(wsID)
        }
        saveAll()
    }

    func deleteWorkspace(id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }

        // Clean up agent trust entries
        AgentSetup.shared.untrustCodexProject(path: workspace.path)

        // Remove directory
        if FileManager.default.fileExists(atPath: workspace.path) {
            try? FileManager.default.removeItem(atPath: workspace.path)
        }

        workspaces.removeAll { $0.id == id }
        if activeWorkspaceID == id {
            activeWorkspaceID = nil
        }
        saveAll()
    }

    func updateWorkspaceStatus(id: UUID, status: Workspace.Status) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].status = status
        saveAll()
    }

    private func restoreSelection() {
        let state = ForgeStore.shared.loadStateFields()
        if let savedProjectID = state.activeProjectID,
           projects.contains(where: { $0.id == savedProjectID })
        {
            activeProjectID = savedProjectID
            activeWorkspaceID = state.activeWorkspaceID
            return
        }

        if activeProjectID == nil {
            activeProjectID = projects.first?.id
            activeWorkspaceID = nil
        }
    }
}
