import Combine
import Foundation

enum SplitAxis {
    case vertical
    case horizontal
}

@MainActor
class TerminalSessionManager: ObservableObject {
    static let shared = TerminalSessionManager()

    @Published var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID?
    @Published var focusedSessionID: UUID?

    var activeProjectID: UUID?
    var activeWorkspaceID: UUID?

    private(set) var lastActiveTabByScope: [String: UUID] = [:]

    private func scopeKey(projectID: UUID?, workspaceID: UUID?) -> String {
        "\(projectID?.uuidString ?? "")|\(workspaceID?.uuidString ?? "")"
    }

    private func resolveWorkingDirectory(
        projectID: UUID?,
        workspaceID: UUID?
    ) -> String? {
        if let wsID = workspaceID,
           let ws = ProjectStore.shared.workspaces.first(where: { $0.id == wsID })
        {
            return ws.path
        }
        return ProjectStore.shared.projects.first(where: { $0.id == projectID })?.path
    }

    var visibleTabs: [TerminalTab] {
        tabs.filter {
            $0.projectID == activeProjectID &&
                $0.workspaceID == activeWorkspaceID
        }
    }

    var visibleSessions: [TerminalSession] {
        let ids = Set(visibleTabs.flatMap { $0.paneManager?.allSessionIDs ?? $0.sessionIDs })
        return sessions.filter { ids.contains($0.id) }
    }

    private(set) var sessions: [TerminalSession] = []
    private var saveWorkItem: DispatchWorkItem?
    private var persistenceCancellables = Set<AnyCancellable>()
    private var isRestoringState = false
    private let saveDebounceInterval: TimeInterval = 0.4

    /// Scrollback text from previous session, keyed by session UUID string.
    /// Consumed once during terminal creation, then cleared per-session.
    var restoredScrollback: [String: String] = [:]

    /// Split layout snapshots from previous session, keyed by tab UUID string.
    /// Consumed once during pane manager setup, then cleared per-tab.
    var restoredSplitLayouts: [String: SplitLayoutSnapshot] = [:]

    /// Session IDs that were restored from a previous app session (not newly created).
    /// Used to inject commands without auto-executing them.
    var restoredSessionIDs: Set<UUID> = []

    /// Workspace IDs for newly created workspaces. Consumed once when the first
    /// terminal session is created, to auto-run the welcome screen.
    var newlyCreatedWorkspaceIDs: Set<UUID> = []

    /// Paths to welcome function files, keyed by workspace ID.
    /// Every terminal in a workspace sources this file to get the `welcome` command.
    var welcomeFunctionPaths: [UUID: String] = [:]

    /// Session IDs that should auto-run `welcome` on first prompt.
    var pendingShowWelcome: Set<UUID> = []

    private init() {
        loadPersistedState()
        observeStateForPersistence()
    }

    // MARK: - Session helpers

    func session(for id: UUID) -> TerminalSession? {
        sessions.first(where: { $0.id == id })
    }

    /// Add a session to the session list (used by BonsplitPaneManager when splitting).
    func addSession(_ session: TerminalSession) {
        sessions.append(session)
    }

    /// Remove a session from the session list (used by BonsplitPaneManager on close).
    func removeSession(_ sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
    }

    /// Store the agent's own session ID on a terminal session for resume on restart.
    func updateAgentSessionID(_ sessionID: UUID, agentSessionID: String) {
        if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[idx].agentSessionID = agentSessionID
        }
    }

    // MARK: - Pane Manager Setup

    /// Ensure a tab has a BonsplitPaneManager. Creates one if missing.
    @discardableResult
    func ensurePaneManager(for tabIndex: Int) -> BonsplitPaneManager {
        if let existing = tabs[tabIndex].paneManager {
            return existing
        }

        let tab = tabs[tabIndex]
        let manager = BonsplitPaneManager(
            workspaceTabID: tab.id,
            projectID: tab.projectID,
            workspaceID: tab.workspaceID
        )

        // Add existing sessions to bonsplit
        for sessionID in tab.sessionIDs {
            if let session = session(for: sessionID) {
                manager.addSession(session)
            }
        }

        // Handle session cleanup when a pane is closed via Bonsplit
        manager.onSessionClosed = { [weak self] sessionID in
            self?.handleSessionClosed(sessionID)
        }

        tabs[tabIndex].paneManager = manager

        // Restore split layout if available
        if let layout = restoredSplitLayouts.removeValue(forKey: tab.id.uuidString) {
            let dividerPositions = manager.restoreFromLayoutSnapshot(layout)
            // Apply divider positions after a brief delay so the view hierarchy is ready
            if !dividerPositions.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    for (splitID, position) in dividerPositions {
                        manager.controller.setDividerPosition(CGFloat(position), forSplit: splitID, fromExternal: true)
                    }
                }
            }
        }

        return manager
    }

    private func handleSessionClosed(_ sessionID: UUID) {
        TerminalCache.shared.remove(sessionID)
        sessions.removeAll { $0.id == sessionID }

        if let tabIndex = tabs.firstIndex(where: {
            $0.paneManager?.allSessionIDs.contains(sessionID) == true || $0.sessionIDs.contains(sessionID)
        }) {
            tabs[tabIndex].sessionIDs.removeAll { $0 == sessionID }
        }

        // If the tab has no more sessions, close it
        if let tabIndex = tabs.firstIndex(where: {
            let sessionIDs = $0.paneManager?.allSessionIDs ?? $0.sessionIDs
            return sessionIDs.isEmpty
        }) {
            let tab = tabs[tabIndex]
            tabs.remove(at: tabIndex)

            if activeTabID == tab.id {
                let remaining = visibleTabs
                if remaining.isEmpty {
                    activeTabID = nil
                    focusedSessionID = nil
                } else {
                    activeTabID = remaining[0].id
                    focusedSessionID = remaining[0].paneManager?.focusedSessionID
                }
            }

            // Auto-create a shell if no tabs remain for this scope
            if visibleTabs.isEmpty, let pid = tab.projectID {
                let dir = resolveWorkingDirectory(
                    projectID: pid,
                    workspaceID: tab.workspaceID
                ) ?? NSHomeDirectory()
                createSession(
                    workingDirectory: dir,
                    projectID: pid,
                    workspaceID: tab.workspaceID
                )
            }
        }

        // Update focused session from the manager
        if let tabIndex = activeGlobalTabIndex,
           let newFocused = tabs[tabIndex].paneManager?.focusedSessionID
        {
            focusedSessionID = newFocused
        }
    }

    // MARK: - Tab creation

    @discardableResult
    func createSession(
        workingDirectory: String? = nil,
        title: String = "Shell",
        launchCommand: String? = nil,
        closeOnExit: Bool = false,
        projectID: UUID? = nil,
        workspaceID: UUID? = nil,
        icon: String? = nil
    ) -> TerminalSession {
        let pid = projectID ?? activeProjectID
        let wsID = workspaceID ?? activeWorkspaceID
        let dir = workingDirectory ?? resolveWorkingDirectory(
            projectID: pid,
            workspaceID: wsID
        ) ?? NSHomeDirectory()
        let session = TerminalSession(title: title, workingDirectory: dir, launchCommand: launchCommand, closeOnExit: closeOnExit)
        sessions.append(session)

        var tab = TerminalTab(
            projectID: pid,
            workspaceID: wsID,
            sessionID: session.id,
            title: title,
            icon: icon
        )

        // Create pane manager and add the initial session
        let manager = BonsplitPaneManager(
            workspaceTabID: tab.id,
            projectID: pid,
            workspaceID: wsID
        )
        manager.addSession(session)
        manager.onSessionClosed = { [weak self] sessionID in
            self?.handleSessionClosed(sessionID)
        }
        tab.paneManager = manager

        tabs.append(tab)
        activeTabID = tab.id
        focusedSessionID = session.id

        if let pid { ProjectStore.shared.recordActivity(for: pid) }

        return session
    }

    // MARK: - Close

    func closeSession(id: UUID) {
        // Find which tab contains this session
        guard let tabIndex = tabs.firstIndex(where: {
            $0.paneManager?.allSessionIDs.contains(id) == true || $0.sessionIDs.contains(id)
        }) else { return }

        let tab = tabs[tabIndex]
        let paneCount = tab.paneManager?.paneCount ?? tab.sessionIDs.count

        if paneCount <= 1 {
            closeTab(id: tab.id)
        } else {
            // Let Bonsplit close the tab — cleanup happens in handleSessionClosed via delegate
            tab.paneManager?.removeSession(id)
            // Notify container to refresh BonsplitView after tree collapse
            NotificationCenter.default.post(name: .paneSplitLayoutChanged, object: nil)
        }
    }

    func closeTab(id: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[tabIndex]
        let tabProjectID = tab.projectID
        let tabWorkspaceID = tab.workspaceID

        AgentEventStore.shared.clearForTab(id)

        let visibleIndexBefore = visibleTabs.firstIndex(where: { $0.id == id })

        // Clean up all sessions in this tab
        let allIDs = tab.paneManager?.allSessionIDs ?? tab.sessionIDs
        for sessionID in allIDs {
            TerminalCache.shared.remove(sessionID)
            sessions.removeAll { $0.id == sessionID }
        }

        tabs.remove(at: tabIndex)

        if activeTabID == id {
            let remaining = visibleTabs
            if remaining.isEmpty {
                activeTabID = nil
                focusedSessionID = nil
            } else {
                let preferred = visibleIndexBefore.map { min($0, remaining.count - 1) } ?? 0
                activeTabID = remaining[preferred].id
                focusedSessionID = remaining[preferred].paneManager?.focusedSessionID
            }
        }

        // Only auto-create shell if no visible terminal tabs remain (not diff tabs)
        let visibleTerminalTabs = visibleTabs.filter(\.kind.isTerminal)
        if visibleTerminalTabs.isEmpty, let pid = tabProjectID {
            let dir = resolveWorkingDirectory(
                projectID: pid,
                workspaceID: tabWorkspaceID
            ) ?? NSHomeDirectory()
            createSession(
                workingDirectory: dir,
                projectID: pid,
                workspaceID: tabWorkspaceID
            )
        }
    }

    // MARK: - Changes Tab

    /// Opens (or reuses) the shared changes tab, optionally scrolling to a file.
    func openChangesTab(repoPath: String, scrollToFile: String? = nil) {
        // Reuse existing changes tab
        if let existing = visibleTabs.first(where: { $0.kind.isChanges }) {
            activeTabID = existing.id
            focusedSessionID = nil
            // Post scroll request
            if let file = scrollToFile {
                NotificationCenter.default.post(
                    name: .scrollToFileInChanges,
                    object: nil,
                    userInfo: ["filePath": file]
                )
            }
            return
        }

        let tab = TerminalTab(
            id: UUID(),
            projectID: activeProjectID,
            workspaceID: activeWorkspaceID,
            sessionID: UUID(),
            title: "Pending Changes",
            icon: "doc.text.magnifyingglass",
            kind: .changes(repoPath: repoPath)
        )

        tabs.append(tab)
        activeTabID = tab.id
        focusedSessionID = nil

        // Post scroll request after a brief delay to let the view appear
        if let file = scrollToFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(
                    name: .scrollToFileInChanges,
                    object: nil,
                    userInfo: ["filePath": file]
                )
            }
        }
    }

    // MARK: - Workspace Diff Tab

    /// Opens (or reuses) the workspace diff tab, optionally scrolling to a file.
    func openWorkspaceDiffTab(repoPath: String, baseRef: String, scrollToFile: String? = nil) {
        // Reuse existing workspace diff tab
        if let existing = visibleTabs.first(where: { $0.kind.isWorkspaceDiff }) {
            activeTabID = existing.id
            focusedSessionID = nil
            if let file = scrollToFile {
                NotificationCenter.default.post(
                    name: .scrollToFileInWorkspaceDiff,
                    object: nil,
                    userInfo: ["filePath": file]
                )
            }
            return
        }

        let tab = TerminalTab(
            id: UUID(),
            projectID: activeProjectID,
            workspaceID: activeWorkspaceID,
            sessionID: UUID(),
            title: "Workspace Changes",
            icon: "arrow.triangle.branch",
            kind: .workspaceDiff(repoPath: repoPath, baseRef: baseRef)
        )

        tabs.append(tab)
        activeTabID = tab.id
        focusedSessionID = nil

        if let file = scrollToFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NotificationCenter.default.post(
                    name: .scrollToFileInWorkspaceDiff,
                    object: nil,
                    userInfo: ["filePath": file]
                )
            }
        }
    }

    // MARK: - Tab activation

    func activateSession(id: UUID) {
        for tab in tabs {
            if tab.paneManager?.allSessionIDs.contains(id) == true || tab.sessionIDs.contains(id) {
                activeTabID = tab.id
                focusedSessionID = id
                return
            }
        }
    }

    func activateTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        activeTabID = tab.id
        focusedSessionID = tab.paneManager?.focusedSessionID
    }

    func renameTab(id: UUID, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = title
    }

    /// Update tab titles based on detected agents. Called when agent detection changes.
    func refreshAgentTitles() {
        let agents = AgentStore.shared.agents
        for i in tabs.indices {
            let sessionIDs = tabs[i].paneManager?.allSessionIDs ?? tabs[i].sessionIDs
            guard let primarySession = sessionIDs.first else { continue }

            if let agentCommand = TerminalObserver.shared.detectAgent(sessionID: primarySession),
               let agent = agents.first(where: { $0.command == agentCommand })
            {
                // Set to agent display name and icon
                if tabs[i].title != agent.name {
                    tabs[i].title = agent.name
                    tabs[i].icon = agent.icon
                }
            } else {
                // Revert to Shell if it was previously an agent tab
                let agentNames = Set(agents.map(\.name))
                if agentNames.contains(tabs[i].title) {
                    tabs[i].title = "Shell"
                    tabs[i].icon = nil
                }
            }
        }
    }

    func activateTab(at index: Int) {
        let visible = visibleTabs
        guard index >= 0, index < visible.count else { return }
        activeTabID = visible[index].id
        focusedSessionID = visible[index].paneManager?.focusedSessionID
    }

    func activeTabIndex() -> Int? {
        guard let id = activeTabID else { return nil }
        return visibleTabs.firstIndex(where: { $0.id == id })
    }

    var activeTab: TerminalTab? {
        guard let id = activeTabID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    // MARK: - Project switching

    func switchProject(to projectID: UUID?, workspaceID: UUID? = nil) {
        if let currentTab = activeTabID {
            let oldKey = scopeKey(
                projectID: activeProjectID,
                workspaceID: activeWorkspaceID
            )
            lastActiveTabByScope[oldKey] = currentTab
        }

        activeProjectID = projectID
        activeWorkspaceID = workspaceID

        let newKey = scopeKey(projectID: projectID, workspaceID: workspaceID)
        if let savedTab = lastActiveTabByScope[newKey],
           visibleTabs.contains(where: { $0.id == savedTab })
        {
            activeTabID = savedTab
            focusedSessionID = tabs.first(where: { $0.id == savedTab })?.paneManager?.focusedSessionID
        } else if let firstVisible = visibleTabs.first {
            activeTabID = firstVisible.id
            focusedSessionID = firstVisible.paneManager?.focusedSessionID
        } else if let pid = projectID {
            let dir = resolveWorkingDirectory(
                projectID: pid,
                workspaceID: workspaceID
            ) ?? NSHomeDirectory()
            let isNewWorkspace = workspaceID.map { newlyCreatedWorkspaceIDs.remove($0) != nil } ?? false

            let session = createSession(
                workingDirectory: dir,
                projectID: pid,
                workspaceID: workspaceID
            )
            if isNewWorkspace {
                pendingShowWelcome.insert(session.id)
            }
        } else {
            activeTabID = nil
            focusedSessionID = nil
        }

        schedulePersistState()
    }

    // MARK: - Split panes (delegated to BonsplitPaneManager)

    @discardableResult
    func splitFocusedPane(axis: SplitAxis) -> UUID? {
        guard let tabIndex = activeGlobalTabIndex else { return nil }
        let manager = ensurePaneManager(for: tabIndex)
        let dir = focusedSessionID.flatMap { session(for: $0)?.workingDirectory } ?? NSHomeDirectory()
        let orientation: SplitOrientation = (axis == .vertical) ? .horizontal : .vertical
        guard let newSessionID = manager.split(orientation: orientation, workingDirectory: dir) else { return nil }
        tabs[tabIndex].sessionIDs.append(newSessionID)
        focusedSessionID = newSessionID
        return newSessionID
    }

    func closeFocusedPane() {
        guard let focused = focusedSessionID else { return }
        closeSession(id: focused)
    }

    // MARK: - Focus navigation

    func focusNextPane() {
        guard let tabIndex = activeGlobalTabIndex else { return }
        let manager = ensurePaneManager(for: tabIndex)
        manager.navigateFocus(direction: .right)
        focusedSessionID = manager.focusedSessionID
    }

    func focusPreviousPane() {
        guard let tabIndex = activeGlobalTabIndex else { return }
        let manager = ensurePaneManager(for: tabIndex)
        manager.navigateFocus(direction: .left)
        focusedSessionID = manager.focusedSessionID
    }

    func focusPane(direction: NavigationDirection) {
        guard let tabIndex = activeGlobalTabIndex else { return }
        let manager = ensurePaneManager(for: tabIndex)
        manager.navigateFocus(direction: direction)
        focusedSessionID = manager.focusedSessionID
    }

    func setFocusedSession(_ sessionID: UUID) {
        focusedSessionID = sessionID
    }

    // MARK: - Lookup helpers

    func workspaceID(for tabID: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabID })?.workspaceID
    }

    // MARK: - Welcome Function

    /// Ensure the welcome function file exists for a workspace.
    /// Called lazily when creating terminal views so all terminals get it.
    func ensureWelcomeFunction(workspaceID: UUID) {
        guard welcomeFunctionPaths[workspaceID] == nil else { return }
        guard let ws = ProjectStore.shared.workspaces.first(where: { $0.id == workspaceID }) else { return }

        let agents = AgentStore.shared.agents
            .filter(\.isInstalled)
            .map { (name: $0.name, command: $0.command) }

        welcomeFunctionPaths[workspaceID] = WorkspaceWelcomeScreen.writeFunction(
            workspaceID: workspaceID,
            workspaceName: ws.name,
            workspacePath: ws.path,
            agents: agents
        )
    }

    // MARK: - Private helpers

    private var activeGlobalTabIndex: Int? {
        guard let id = activeTabID else { return nil }
        return tabs.firstIndex(where: { $0.id == id })
    }

    // MARK: - Persistence

    private func observeStateForPersistence() {
        Publishers.CombineLatest3($tabs, $activeTabID, $focusedSessionID)
            .dropFirst()
            .sink { [weak self] _, _, _ in
                self?.schedulePersistState()
            }
            .store(in: &persistenceCancellables)
    }

    private func schedulePersistState() {
        guard !isRestoringState else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persistState()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: item)
    }

    private func persistState() {
        persistState(includeScrollback: false)
    }

    func persistState(includeScrollback: Bool) {
        guard !isRestoringState else { return }
        let terminalTabs = tabs.filter(\.kind.isTerminal)

        // Build scope-based structure
        var scopes: [String: ScopeState] = [:]
        var scrollback: [String: String] = [:]

        // Group tabs by scope
        var tabsByScope: [String: [TerminalTab]] = [:]
        for tab in terminalTabs {
            let key = scopeKey(projectID: tab.projectID, workspaceID: tab.workspaceID)
            tabsByScope[key, default: []].append(tab)
        }

        for (key, scopeTabs) in tabsByScope {
            let entries = scopeTabs.map { tab -> TabEntry in
                let tabSessions = tab.sessionIDs.compactMap { id in
                    sessions.first { $0.id == id }
                }
                let layout = tab.paneManager?.splitLayoutSnapshot()

                if includeScrollback {
                    let ids = tab.paneManager?.allSessionIDs ?? tab.sessionIDs
                    for sessionID in ids {
                        if let view = TerminalCache.shared.view(for: sessionID),
                           let text = view.captureScrollback()
                        {
                            scrollback[sessionID.uuidString] = text
                        }
                    }
                }

                return TabEntry(tab: tab, sessions: tabSessions, splitLayout: layout)
            }
            scopes[key] = ScopeState(activeTab: lastActiveTabByScope[key], tabs: entries)
        }

        var state = ForgeStore.shared.loadStateFields()
        state.scopes = scopes
        state.scrollback = includeScrollback ? scrollback : state.scrollback
        ForgeStore.shared.saveSessionState(state)
    }

    private func loadPersistedState() {
        guard let persisted = ForgeStore.shared.loadSessionState() else { return }

        let validProjectIDs = Set(ProjectStore.shared.projects.map(\.id))
        var restoredTabs: [TerminalTab] = []
        var restoredSessions: [TerminalSession] = []
        var restoredLastActive: [String: UUID] = [:]
        var restoredLayouts: [String: SplitLayoutSnapshot] = [:]

        for (key, scope) in persisted.scopes {
            // Parse scope key to get projectID/workspaceID
            let parts = key.split(separator: "|", omittingEmptySubsequences: false)
            let projectID = parts.count > 0 ? UUID(uuidString: String(parts[0])) : nil
            let workspaceID = parts.count > 1 ? UUID(uuidString: String(parts[1])) : nil

            // Skip tabs for deleted projects
            if let pid = projectID, !validProjectIDs.contains(pid) { continue }

            for entry in scope.tabs {
                let tabSessions = entry.toSessions()
                guard !tabSessions.isEmpty else { continue }

                var tab = entry.toTab(projectID: projectID, workspaceID: workspaceID)
                tab.sessionIDs = tabSessions.map(\.id)
                restoredTabs.append(tab)
                restoredSessions.append(contentsOf: tabSessions)

                if let layout = entry.splitLayout {
                    restoredLayouts[tab.id.uuidString] = layout
                }
            }

            if let activeTab = scope.activeTab {
                restoredLastActive[key] = activeTab
            }
        }

        // Validate working directories
        for index in restoredSessions.indices {
            restoredSessions[index].isRunning = true
            let directory = restoredSessions[index].workingDirectory
            if directory.isEmpty || !FileManager.default.fileExists(atPath: directory) {
                let tab = restoredTabs.first { $0.sessionIDs.contains(restoredSessions[index].id) }
                if let fallback = resolveWorkingDirectory(projectID: tab?.projectID, workspaceID: tab?.workspaceID) {
                    restoredSessions[index].workingDirectory = fallback
                } else {
                    restoredSessions[index].workingDirectory = NSHomeDirectory()
                }
            }
        }

        isRestoringState = true
        sessions = restoredSessions
        tabs = restoredTabs
        lastActiveTabByScope = restoredLastActive
        restoredScrollback = persisted.scrollback
        restoredSplitLayouts = restoredLayouts
        restoredSessionIDs = Set(restoredSessions.map(\.id))
        activeTabID = nil
        focusedSessionID = nil
        isRestoringState = false
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let paneSplitLayoutChanged = Notification.Name("paneSplitLayoutChanged")
    static let scrollToFileInChanges = Notification.Name("scrollToFileInChanges")
    static let scrollToFileInWorkspaceDiff = Notification.Name("scrollToFileInWorkspaceDiff")
}
