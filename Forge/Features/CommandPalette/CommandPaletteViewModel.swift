import AppKit
import Foundation

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    @Published var query = ""

    @Published var sections: [CPSection] = []
    @Published var selectedItemID: String?

    private var commandCache: [ProjectCommand] = []
    private var actions: [CPAction] = []

    // MARK: - Lifecycle

    func activate() {
        query = ""
        selectedItemID = nil

        let store = ProjectStore.shared
        if let project = store.activeProject {
            let path = store.effectivePath ?? project.path
            commandCache = discoverProjectCommands(at: path)
        } else {
            commandCache = []
        }

        actions = CPAction.all(editors: store.availableEditors)
        rebuildSections(for: "")
    }

    // MARK: - Section building

    func rebuildSections(for rawQuery: String) {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [CPSection] = []

        if let s = buildSwitchTo(query: q) { result.append(s) }
        if let s = buildRun(query: q) { result.append(s) }
        if let s = buildDo(query: q) { result.append(s) }

        sections = result
        syncSelection()
    }

    private func buildSwitchTo(query: String) -> CPSection? {
        let store = ProjectStore.shared
        let activeProjectID = store.activeProjectID
        let activeWorkspaceID = store.activeWorkspaceID

        struct Scored {
            let item: CPItem
            let score: Int
        }

        var scored: [Scored] = []

        for project in store.projects {
            let projectWorkspaces = store.workspaces(for: project.id)
                .filter { $0.status == .active }

            // Score project
            let isActive = project.id == activeProjectID && activeWorkspaceID == nil
            if !isActive {
                let matchScore: Int = if query.isEmpty {
                    0
                } else if let s = FuzzyMatch.score(pattern: query, in: project.name) {
                    s
                } else {
                    -1
                }

                var boost = 0
                if project.id == activeProjectID { boost += 1000 }
                if let lastActive = project.lastActiveAt {
                    boost += Int(max(0, 100 - Date().timeIntervalSince(lastActive) / 3600))
                }

                if matchScore >= 0 {
                    scored.append(Scored(
                        item: .project(id: project.id, name: project.name, path: abbreviate(project.path)),
                        score: matchScore + boost
                    ))
                }
            }

            // Score workspaces
            for ws in projectWorkspaces {
                let isCurrent = ws.id == activeWorkspaceID
                guard !isCurrent else { continue }

                let wsScore: Int
                if query.isEmpty {
                    wsScore = 0
                } else if let s = FuzzyMatch.score(pattern: query, in: ws.name) {
                    wsScore = s
                } else {
                    continue
                }

                var boost = 0
                if project.id == activeProjectID { boost += 1000 }

                scored.append(Scored(
                    item: .workspace(id: ws.id, name: ws.name, projectName: project.name, branch: ws.parentBranch),
                    score: wsScore + boost
                ))
            }
        }

        scored.sort { $0.score > $1.score }
        let items = Array(scored.prefix(8).map(\.item))
        guard !items.isEmpty else { return nil }
        return CPSection(id: "switch-to", title: "SWITCH TO", items: items)
    }

    private func buildRun(query: String) -> CPSection? {
        struct Scored {
            let item: CPItem
            let score: Int
        }

        let limit = query.isEmpty ? 5 : 8

        var scored: [Scored] = []
        for cmd in commandCache {
            if query.isEmpty {
                scored.append(Scored(
                    item: .command(id: cmd.id, name: cmd.name, cmd: cmd.command, source: cmd.source.rawValue),
                    score: 0
                ))
            } else {
                guard let best = FuzzyMatch.score(pattern: query, in: cmd.name) else { continue }
                scored.append(Scored(
                    item: .command(id: cmd.id, name: cmd.name, cmd: cmd.command, source: cmd.source.rawValue),
                    score: best
                ))
            }
        }

        scored.sort { $0.score > $1.score }
        let items = Array(scored.prefix(limit).map(\.item))
        guard !items.isEmpty else { return nil }
        return CPSection(id: "run", title: "RUN", items: items)
    }

    private func buildDo(query: String) -> CPSection? {
        let items: [CPItem] = if query.isEmpty {
            actions.map { .action($0) }
        } else {
            actions.compactMap { action -> (CPItem, Int)? in
                guard let score = FuzzyMatch.score(pattern: query, in: action.name) else { return nil }
                return (.action(action), score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }
        guard !items.isEmpty else { return nil }
        return CPSection(id: "do", title: "DO", items: items)
    }

    // MARK: - Selection

    private func syncSelection() {
        let all = sections.flatMap(\.items)
        if let selectedItemID, all.contains(where: { $0.id == selectedItemID }) { return }
        selectedItemID = all.first?.id
    }

    func moveSelection(by delta: Int) {
        let all = sections.flatMap(\.items)
        guard !all.isEmpty else { return }
        guard let selectedItemID, let idx = all.firstIndex(where: { $0.id == selectedItemID }) else {
            selectedItemID = all.first?.id
            return
        }
        self.selectedItemID = all[(idx + delta + all.count) % all.count].id
    }

    func executeSelected() {
        let all = sections.flatMap(\.items)
        guard let item = all.first(where: { $0.id == selectedItemID }) ?? all.first else { return }
        execute(item)
    }

    // MARK: - Execute

    func execute(_ item: CPItem) {
        let store = ProjectStore.shared

        switch item {
        case let .project(id, _, _):
            store.activeProjectID = id
            store.activeWorkspaceID = nil

        case let .workspace(id, _, _, _):
            guard let ws = store.workspaces.first(where: { $0.id == id }) else { return }
            store.activeProjectID = ws.projectID
            store.activeWorkspaceID = ws.id

        case let .command(id, _, _, _):
            guard let cmd = commandCache.first(where: { $0.id == id }) else { return }
            let dir = cmd.workingDirectory ?? store.effectivePath ?? NSHomeDirectory()
            let pid = store.activeProjectID
            let wsID = store.activeWorkspaceID
            Task { @MainActor in
                TerminalSessionManager.shared.createSession(
                    workingDirectory: dir, title: cmd.name, launchCommand: cmd.command,
                    projectID: pid, workspaceID: wsID
                )
            }

        case let .action(action):
            executeAction(action)
        }
    }

    private func executeAction(_ action: CPAction) {
        let store = ProjectStore.shared

        switch action.id {
        case "new-ws":
            guard let project = store.activeProject else { return }
            let branch = project.defaultBranch
            store.creatingWorkspaceForProject.insert(project.id)
            ToastManager.shared.showModal("Creating workspace…")
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try WorkspaceCloner.createWorkspace(
                        projectID: project.id, projectName: project.name,
                        projectPath: project.path, parentBranch: branch,
                        progress: { step in
                            DispatchQueue.main.async {
                                ToastManager.shared.showModal(step)
                            }
                        }
                    )
                    let ws = result.workspace
                    let setupFailed = result.setupFailed
                    DispatchQueue.main.async {
                        store.creatingWorkspaceForProject.remove(project.id)
                        store.addWorkspace(ws)
                        store.activeWorkspaceID = ws.id
                        ToastManager.shared.dismissModal()
                        if let failure = setupFailed {
                            ToastManager.shared.show(
                                "Setup failed: \(failure.message)", severity: .error, duration: 8.0,
                                action: .init(label: "Open Terminal") {
                                    TerminalSessionManager.shared.createSession(workingDirectory: ws.path)
                                }
                            )
                        } else {
                            ToastManager.shared.show("Created workspace '\(ws.name)'")
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        store.creatingWorkspaceForProject.remove(project.id)
                        ToastManager.shared.dismissModal()
                        ToastManager.shared.show(error.localizedDescription, severity: .error)
                    }
                }
            }

        case "new-tab":
            TerminalSessionManager.shared.createSession()

        case "split-v":
            TerminalSessionManager.shared.splitFocusedPane(axis: .vertical)

        case "split-h":
            TerminalSessionManager.shared.splitFocusedPane(axis: .horizontal)

        case "sidebar":
            NSApp.sendAction(#selector(MainSplitViewController.toggleLeftSidebar(_:)), to: nil, from: nil)

        case "inspector":
            NSApp.sendAction(#selector(MainSplitViewController.toggleRightSidebar(_:)), to: nil, from: nil)

        case "settings":
            SettingsWindowController.shared.showSettings()

        case "add-project":
            NotificationCenter.default.post(name: .openProjectRequested, object: nil)

        default:
            // Editor actions: "editor-<name>"
            if action.id.hasPrefix("editor-") {
                guard let path = store.effectivePath else { return }
                let editorName = String(action.id.dropFirst("editor-".count))
                guard let editor = store.availableEditors.first(where: {
                    $0.name.lowercased() == editorName
                }) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = editor.command.components(separatedBy: " ") + [path]
                    try? process.run()
                }
            }
        }
    }

    // MARK: - Helpers

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
