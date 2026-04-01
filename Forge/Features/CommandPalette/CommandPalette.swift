import AppKit
import SwiftUI

final class CommandPalette {
    static let shared = CommandPalette()

    private var panel: NSPanel?
    private var searchField: NSTextField?
    private var resultsHostView: NSView?
    private var sections: [CPSection] = []
    private var selectedItemID: String?
    private var commandCache: [ProjectCommand] = []

    private init() {}

    func toggle(from window: NSWindow?) {
        if let panel, panel.isVisible {
            close()
        } else {
            show(from: window)
        }
    }

    func show(from window: NSWindow?) {
        guard let window else { return }
        close()

        refreshCommands()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        let theme = TerminalAppearanceStore.shared.config.theme
        panel.appearance = theme.nsAppearance
        panel.backgroundColor = theme.popoverBackground
        panel.hasShadow = true

        // Center in main window
        let f = window.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.midY + 20))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        container.wantsLayer = true

        // Search icon
        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            icon.image = img.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }
        icon.contentTintColor = .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)

        // Search field
        let field = NSTextField()
        field.placeholderString = "Search projects, workspaces, branches, commands..."
        field.font = .systemFont(ofSize: 14)
        field.textColor = .labelColor
        field.backgroundColor = .clear
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.translatesAutoresizingMaskIntoConstraints = false
        searchField = field
        container.addSubview(field)

        // Divider
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        // Results
        rebuildSections()
        let host = NSHostingController(rootView: makeResultsView())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        resultsHostView = host.view

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 15),

            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 11),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            host.view.topAnchor.constraint(equalTo: divider.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        panel.contentView = container
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)), name: NSControl.textDidChangeNotification, object: field)

        self.panel = panel

        // Key handler for arrows/enter/escape within the panel
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            switch event.keyCode {
            case 53: close(); return nil // Escape
            case 125: moveSelection(by: 1); return nil // Down
            case 126: moveSelection(by: -1); return nil // Up
            case 36, 76: applySelected(); return nil // Enter
            default: return event
            }
        }
    }

    func close() {
        panel?.close()
        panel = nil
        searchField = nil
        resultsHostView = nil
        selectedItemID = nil
    }

    // MARK: - Text changed

    @objc private func textChanged(_: Notification) {
        rebuildSections()
        updateResults()
    }

    // MARK: - Build sections

    private func rebuildSections() {
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var result: [CPSection] = []
        let store = ProjectStore.shared

        // Projects
        let projects = store.projects
            .filter { match(query, in: [$0.name]) }
            .sorted { rank(query, $0.name) < rank(query, $1.name) }
            .prefix(5)
            .map { CPItem.project(id: $0.id.uuidString, name: $0.name, path: abbreviate($0.path)) }
        if !projects.isEmpty { result.append(CPSection(title: "PROJECTS", items: Array(projects))) }

        // Workspaces
        let workspaces = store.workspaces
            .filter { $0.status == .active && match(query, in: [$0.name, $0.parentBranch]) }
            .sorted { rank(query, $0.name) < rank(query, $1.name) }
            .prefix(6)
            .map { CPItem.workspace(id: $0.id.uuidString, name: $0.name, from: $0.parentBranch) }
        if !workspaces.isEmpty { result.append(CPSection(title: "WORKSPACES", items: Array(workspaces))) }

        // Branches
        let branches = (store.allBranches.isEmpty ? [store.currentBranch].filter { !$0.isEmpty } : store.allBranches)
            .filter { match(query, in: [$0]) }
            .sorted { rank(query, $0) < rank(query, $1) }
            .prefix(8)
            .map { CPItem.branch(name: $0) }
        if !branches.isEmpty { result.append(CPSection(title: "BRANCHES", items: Array(branches))) }

        // Commands
        let commands = commandCache
            .filter { match(query, in: [$0.name, $0.command]) }
            .sorted { rank(query, $0.name) < rank(query, $1.name) }
            .prefix(6)
            .map { CPItem.command(id: $0.id.uuidString, name: $0.name, cmd: $0.command) }
        if !commands.isEmpty { result.append(CPSection(title: "COMMANDS", items: Array(commands))) }

        // Actions
        var actions: [CPItem] = []
        if match(query, in: ["new workspace", "create"]) {
            actions.append(.action(id: "new-ws", name: "New Workspace", subtitle: "From default branch", icon: "plus.square.on.square"))
        }
        if match(query, in: ["settings", "preferences"]) {
            actions.append(.action(id: "settings", name: "Settings", subtitle: "\u{2318},", icon: "gearshape"))
        }
        if match(query, in: ["add project", "open"]) {
            actions.append(.action(id: "add-project", name: "Add Project", subtitle: "\u{2318}\u{21E7}O", icon: "folder.badge.plus"))
        }
        if !actions.isEmpty { result.append(CPSection(title: "ACTIONS", items: actions)) }

        sections = result
        syncSelection()
    }

    private func refreshCommands() {
        guard let project = ProjectStore.shared.activeProject else { commandCache = []; return }
        let path = ProjectStore.shared.effectivePath ?? project.path
        commandCache = discoverProjectCommands(at: path)
    }

    // MARK: - Selection

    private func syncSelection() {
        let all = sections.flatMap(\.items)
        if let selectedItemID, all.contains(where: { $0.id == selectedItemID }) { return }
        selectedItemID = all.first?.id
    }

    private func moveSelection(by delta: Int) {
        let all = sections.flatMap(\.items)
        guard !all.isEmpty else { return }
        guard let selectedItemID, let idx = all.firstIndex(where: { $0.id == selectedItemID }) else {
            self.selectedItemID = all.first?.id
            updateResults()
            return
        }
        self.selectedItemID = all[(idx + delta + all.count) % all.count].id
        updateResults()
    }

    private func applySelected() {
        let all = sections.flatMap(\.items)
        guard let item = all.first(where: { $0.id == selectedItemID }) ?? all.first else { return }
        close()
        execute(item)
    }

    // MARK: - Execute

    private func execute(_ item: CPItem) {
        let store = ProjectStore.shared

        switch item {
        case let .project(id, _, _):
            guard let uuid = UUID(uuidString: id) else { return }
            store.activeProjectID = uuid
            store.activeWorkspaceID = nil

        case let .workspace(id, _, _):
            guard let uuid = UUID(uuidString: id),
                  let ws = store.workspaces.first(where: { $0.id == uuid }) else { return }
            store.activeProjectID = ws.projectID
            store.activeWorkspaceID = ws.id

        case let .branch(name):
            guard let path = store.effectivePath else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Git.shared.run(in: path, args: ["checkout", name])
                DispatchQueue.main.async {
                    if result.success {
                        store.currentBranch = name
                        store.requestGitRefresh()
                    }
                }
            }

        case let .command(id, _, _):
            guard let uuid = UUID(uuidString: id),
                  let cmd = commandCache.first(where: { $0.id == uuid }) else { return }
            let dir = cmd.workingDirectory ?? store.effectivePath ?? NSHomeDirectory()
            let pid = store.activeProjectID
            let wsID = store.activeWorkspaceID
            let name = cmd.name
            let command = cmd.command
            Task { @MainActor in
                TerminalSessionManager.shared.createSession(
                    workingDirectory: dir, title: name, launchCommand: command,
                    projectID: pid, workspaceID: wsID
                )
            }

        case let .action(id, _, _, _):
            switch id {
            case "new-ws":
                guard let project = store.activeProject else { return }
                let branch = store.currentBranch.isEmpty ? project.defaultBranch : store.currentBranch
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let ws = try? WorkspaceCloner.createWorkspace(
                        projectID: project.id, projectName: project.name,
                        projectPath: project.path, parentBranch: branch
                    ) else { return }
                    DispatchQueue.main.async {
                        store.addWorkspace(ws)
                        store.activeWorkspaceID = ws.id
                    }
                }
            case "settings":
                SettingsWindowController.shared.showSettings()
            case "add-project":
                NotificationCenter.default.post(name: .openProjectRequested, object: nil)
            default: break
            }
        }
    }

    // MARK: - Update results view

    private func updateResults() {
        guard let panel, let container = panel.contentView else { return }
        resultsHostView?.removeFromSuperview()

        let host = NSHostingController(rootView: makeResultsView())
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        resultsHostView = host.view

        if let divider = container.subviews.first(where: { ($0.layer?.backgroundColor) != nil && $0.frame.height <= 1 }) {
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: divider.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
    }

    private func makeResultsView() -> some View {
        CPResultsView(sections: sections, selectedItemID: selectedItemID) { [weak self] item in
            self?.close()
            self?.execute(item)
        }
    }

    // MARK: - Helpers

    private func match(_ query: String, in texts: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        return texts.contains { $0.lowercased().contains(query) }
    }

    private func rank(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let v = text.lowercased()
        if v.hasPrefix(query) { return 0 }
        if v.contains(query) { return 1 }
        return 2
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Data types (value types for SwiftUI)

enum CPItem: Identifiable, Hashable {
    case project(id: String, name: String, path: String)
    case workspace(id: String, name: String, from: String)
    case branch(name: String)
    case command(id: String, name: String, cmd: String)
    case action(id: String, name: String, subtitle: String, icon: String)

    var id: String {
        switch self {
        case let .project(id, _, _): "p:\(id)"
        case let .workspace(id, _, _): "w:\(id)"
        case let .branch(name): "b:\(name)"
        case let .command(id, _, _): "c:\(id)"
        case let .action(id, _, _, _): "a:\(id)"
        }
    }

    var title: String {
        switch self {
        case let .project(_, n, _): n
        case let .workspace(_, n, _): n
        case let .branch(n): n
        case let .command(_, n, _): n
        case let .action(_, n, _, _): n
        }
    }

    var subtitle: String {
        switch self {
        case let .project(_, _, p): p
        case let .workspace(_, _, f): "from \(f)"
        case .branch: "Checkout branch"
        case let .command(_, _, c): c
        case let .action(_, _, s, _): s
        }
    }

    var icon: String {
        switch self {
        case .project: "folder"
        case .workspace: "arrow.triangle.branch"
        case .branch: "point.topleft.down.curvedto.point.bottomright.up"
        case .command: "terminal"
        case let .action(_, _, _, i): i
        }
    }
}

struct CPSection: Identifiable {
    let id = UUID()
    let title: String
    let items: [CPItem]
}

// MARK: - Results SwiftUI View

private struct CPResultsView: View {
    let sections: [CPSection]
    let selectedItemID: String?
    let onSelect: (CPItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if sections.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .padding(12)
                } else {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .padding(.horizontal, 14)
                            .padding(.top, 6)

                        ForEach(section.items) { item in
                            let selected = item.id == selectedItemID
                            Button(action: { onSelect(item) }) {
                                HStack(spacing: 10) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 12))
                                        .foregroundColor(selected ? .primary : .secondary)
                                        .frame(width: 16)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(item.subtitle)
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .background(selected ? Color.white.opacity(0.08) : Color.clear)
                                .cornerRadius(5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
