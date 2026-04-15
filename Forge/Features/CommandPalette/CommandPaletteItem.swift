import Foundation

// MARK: - Section

struct CPSection: Identifiable {
    let id: String
    let title: String
    let items: [CPItem]
}

// MARK: - Item

enum CPItem: Identifiable, Hashable {
    case project(id: UUID, name: String, path: String)
    case workspace(id: UUID, name: String, projectName: String, branch: String)
    case command(id: UUID, name: String, cmd: String, source: String)
    case action(CPAction)

    var id: String {
        switch self {
        case let .project(id, _, _): "p:\(id)"
        case let .workspace(id, _, _, _): "w:\(id)"
        case let .command(id, _, _, _): "c:\(id)"
        case let .action(a): "a:\(a.id)"
        }
    }

    var title: String {
        switch self {
        case let .project(_, name, _): name
        case let .workspace(_, name, _, _): name
        case let .command(_, name, _, _): name
        case let .action(a): a.name
        }
    }

    var subtitle: String {
        switch self {
        case let .project(_, _, path): path
        case let .workspace(_, _, projectName, branch): "\(projectName) \u{00B7} \(branch)"
        case let .command(_, _, cmd, _): cmd
        case let .action(a): a.subtitle
        }
    }

    var icon: String {
        switch self {
        case .project: "folder"
        case .workspace: "arrow.triangle.branch"
        case let .command(_, _, _, source): source == "make" ? "terminal" : "terminal"
        case let .action(a): a.icon
        }
    }

    var shortcut: String? {
        switch self {
        case let .action(a): a.shortcut
        default: nil
        }
    }
}

// MARK: - Action

struct CPAction: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let icon: String
    let shortcut: String?

    static let newWorkspace = CPAction(
        id: "new-ws", name: "New Workspace",
        subtitle: "From default branch", icon: "plus.square.on.square", shortcut: nil
    )
    static let newTab = CPAction(
        id: "new-tab", name: "New Tab",
        subtitle: "Open a new terminal tab", icon: "plus.square", shortcut: "\u{2318}T"
    )
    static let splitVertical = CPAction(
        id: "split-v", name: "Split Pane Right",
        subtitle: "Split terminal vertically", icon: "rectangle.split.1x2", shortcut: "\u{2318}D"
    )
    static let splitHorizontal = CPAction(
        id: "split-h", name: "Split Pane Down",
        subtitle: "Split terminal horizontally", icon: "rectangle.split.2x1", shortcut: "\u{21E7}\u{2318}D"
    )
    static let toggleSidebar = CPAction(
        id: "sidebar", name: "Toggle Sidebar",
        subtitle: "Show or hide the sidebar", icon: "sidebar.left", shortcut: "\u{2318}0"
    )
    static let toggleInspector = CPAction(
        id: "inspector", name: "Toggle Inspector",
        subtitle: "Show or hide the inspector", icon: "sidebar.right", shortcut: "\u{2325}\u{2318}0"
    )
    static let settings = CPAction(
        id: "settings", name: "Settings",
        subtitle: "Open preferences", icon: "gearshape", shortcut: "\u{2318},"
    )
    static let addProject = CPAction(
        id: "add-project", name: "Add Project",
        subtitle: "Open a project directory", icon: "folder.badge.plus", shortcut: "\u{21E7}\u{2318}O"
    )
    static let newScratch = CPAction(
        id: "new-scratch", name: "New Scratch",
        subtitle: "Create a throwaway prototype project", icon: "scribble", shortcut: "\u{21E7}\u{2318}N"
    )

    static func openInEditor(_ editor: ExternalEditor) -> CPAction {
        CPAction(
            id: "editor-\(editor.name.lowercased())", name: "Open in \(editor.name)",
            subtitle: editor.command, icon: "arrow.up.forward.app", shortcut: nil
        )
    }

    static func all(editors: [ExternalEditor]) -> [CPAction] {
        var actions: [CPAction] = [
            .newWorkspace, .newTab, .splitVertical, .splitHorizontal,
            .toggleSidebar, .toggleInspector, .settings, .addProject, .newScratch
        ]
        for editor in editors {
            actions.append(openInEditor(editor))
        }
        return actions
    }
}
