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
    @Published var creatingWorkspaceForProject: Set<UUID> = []
    @Published var configReloadTrigger: UInt = 0

    func requestGitRefresh() {
        gitRefreshTrigger += 1
    }

    private var saveWorkItem: DispatchWorkItem?
    private var selectionSaveWorkItem: DispatchWorkItem?
    private var selectionCallbacksEnabled = false
    private let activityThrottleInterval: TimeInterval = 30
    private let selectionPersistenceDebounceInterval: TimeInterval = 0.2

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
        selectionSaveWorkItem?.cancel()
        let projectID = activeProjectID
        let workspaceID = activeWorkspaceID
        let item = DispatchWorkItem {
            ForgeStore.shared.updateStateFields { state in
                state.activeProjectID = projectID
                state.activeWorkspaceID = workspaceID
            }
        }
        selectionSaveWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + selectionPersistenceDebounceInterval,
            execute: item
        )
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

    /// Centralized project selection. Sets both IDs together for scratch projects.
    func selectProject(_ projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        activeProjectID = project.id
        if project.isScratch {
            activeWorkspaceID = workspaces(for: project.id).first?.id
        } else {
            activeWorkspaceID = nil
        }
    }

    func addProject(from url: URL) {
        guard !projects.contains(where: { $0.path == url.path }) else {
            if let existing = projects.first(where: { $0.path == url.path }) {
                activeProjectID = existing.id
                activeWorkspaceID = nil
                Task { @MainActor in ToastManager.shared.show("Switched to '\(existing.name)'") }
            }
            return
        }

        let project = Project(url: url)
        projects.append(project)
        activeProjectID = project.id
        activeWorkspaceID = nil
        saveAll()
        Task { @MainActor in ToastManager.shared.show("Added project '\(project.name)'") }
    }

    /// Apply the result of a successful promotion: replace the scratch records with the new project + workspace.
    func applyPromotion(scratchID: UUID, scratchWorkspaceID: UUID, promoted: ScratchPromotion.Result) {
        // Drop scratch records (the directory has already moved, don't try to delete it again)
        workspaces.removeAll { $0.id == scratchWorkspaceID }
        projects.removeAll { $0.id == scratchID }
        ForgeStore.shared.updateStateFields { state in
            state.collapsedProjects.remove(scratchID)
        }

        // Add new normal project + workspace
        projects.append(promoted.project)
        // Workspace was constructed with the new project's ID inside the cloner, so it's already correct.
        workspaces.append(promoted.workspace.workspace)

        // Activate the new pair
        activeProjectID = promoted.project.id
        activeWorkspaceID = promoted.workspace.workspace.id

        let wsID = promoted.workspace.workspace.id
        Task { @MainActor in
            TerminalSessionManager.shared.newlyCreatedWorkspaceIDs.insert(wsID)
        }
        let parentBranch = promoted.workspace.workspace.parentBranch
        Task { @MainActor in
            ActivityLogStore.shared.append(workspaceID: wsID, event: ActivityEvent(
                kind: .workspaceCreated,
                title: "Workspace created",
                detail: "Created from \(parentBranch)"
            ))
        }
        saveAll()
    }

    /// Create a scratch project + paired workspace at `~/.forge/scratch/<auto-name>/`.
    /// Both records are persisted together; selection lands on both immediately.
    func createScratch() throws {
        let result = try WorkspaceCloner.createScratch()
        let projectID = UUID()
        let project = Project(
            id: projectID,
            name: result.name,
            path: result.path,
            defaultBranch: result.branch,
            kind: .scratch
        )
        var workspace = result.workspace
        workspace.projectID = projectID

        projects.append(project)
        workspaces.append(workspace)
        let wsID = workspace.id
        Task { @MainActor in
            TerminalSessionManager.shared.newlyCreatedWorkspaceIDs.insert(wsID)
        }
        Task { @MainActor in
            ActivityLogStore.shared.append(workspaceID: wsID, event: ActivityEvent(
                kind: .scratchCreated,
                title: "Scratch created"
            ))
        }
        saveAll()
        activeProjectID = projectID
        activeWorkspaceID = workspace.id
        Task { @MainActor in ToastManager.shared.show("Created scratch '\(result.name)'") }
    }

    func removeProject(id: UUID) {
        // Remove associated workspaces
        let projectWorkspaces = workspaces.filter { $0.projectID == id }
        for ws in projectWorkspaces {
            AgentSetup.shared.untrustCodexProject(path: ws.path)
            if FileManager.default.fileExists(atPath: ws.path) {
                try? FileManager.default.removeItem(atPath: ws.path)
            }
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
        // Defensive: scratch projects are single-workspace by design. Use createScratch instead.
        if let project = projects.first(where: { $0.id == workspace.projectID }), project.isScratch {
            assertionFailure("Cannot add a workspace to a scratch project; use createScratch")
            return
        }
        workspaces.append(workspace)
        let wsID = workspace.id
        Task { @MainActor in
            TerminalSessionManager.shared.newlyCreatedWorkspaceIDs.insert(wsID)
        }
        let ws = workspace
        Task { @MainActor in
            ActivityLogStore.shared.append(workspaceID: ws.id, event: ActivityEvent(
                kind: .workspaceCreated,
                title: "Workspace created",
                detail: "Created from \(ws.parentBranch)"
            ))
        }
        saveAll()
    }

    func deleteWorkspace(id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }

        // Clean up activity log
        Task { @MainActor in
            ActivityLogStore.shared.clearLog(workspaceID: id)
        }

        // Clean up agent trust entries
        AgentSetup.shared.untrustCodexProject(path: workspace.path)

        // Remove directory
        if FileManager.default.fileExists(atPath: workspace.path) {
            try? FileManager.default.removeItem(atPath: workspace.path)
        }

        workspaces.removeAll { $0.id == id }

        // For scratch projects, the project and workspace are one entity — drop the project record too.
        let scratchProjectID = projects.first(where: { $0.id == workspace.projectID && $0.isScratch })?.id
        if let scratchProjectID {
            projects.removeAll { $0.id == scratchProjectID }
            ForgeStore.shared.updateStateFields { state in
                state.collapsedProjects.remove(scratchProjectID)
            }
            if activeProjectID == scratchProjectID {
                activeProjectID = projects.first?.id
            }
        }

        if activeWorkspaceID == id {
            activeWorkspaceID = nil
        }
        saveAll()
    }

    func updateWorkspaceStatus(id: UUID, status: Workspace.Status) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        if status == .merged {
            let parentBranch = workspaces[index].parentBranch
            Task { @MainActor in
                ActivityLogStore.shared.append(workspaceID: id, event: ActivityEvent(
                    kind: .workspaceMerged,
                    title: "Merged into \(parentBranch)"
                ))
            }
        }
        workspaces[index].status = status
        saveAll()
    }

    /// Re-read forge.json for a workspace, re-allocate ports, and notify observers.
    func reloadForgeConfig(workspaceID: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let ws = workspaces[idx]

        if let config = ForgeConfig.load(from: ws.path),
           let requested = config.ports, !requested.isEmpty
        {
            let result = PortAllocator.allocatePorts(
                requested: requested,
                existingClaims: ws.allocatedPorts
            )
            workspaces[idx].allocatedPorts = result.allocated
            var details: [String: String] = [:]
            for (envVar, portConfig) in requested {
                if let detail = portConfig.detail {
                    details[envVar] = detail
                }
            }
            workspaces[idx].portDetails = details
        } else {
            workspaces[idx].allocatedPorts = [:]
            workspaces[idx].portDetails = [:]
        }

        saveAll()
        configReloadTrigger += 1
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
