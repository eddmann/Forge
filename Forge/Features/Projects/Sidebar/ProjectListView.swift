import SwiftUI

private struct ScopeActivity {
    let status: AgentStatus
    let sessionCount: Int
}

struct ProjectListView: View {
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var sessionManager = TerminalSessionManager.shared
    @State private var searchText = ""
    @State private var errorMessage: String?

    private var sortedProjects: [Project] {
        store.projects.sorted {
            ($0.lastActiveAt ?? $0.createdAt) > ($1.lastActiveAt ?? $1.createdAt)
        }
    }

    private var filteredProjects: [Project] {
        let projects = sortedProjects
        guard !searchText.isEmpty else { return projects }
        let query = searchText.lowercased()
        return projects.filter { project in
            project.name.lowercased().contains(query) ||
                store.workspaces(for: project.id).contains { $0.name.lowercased().contains(query) }
        }
    }

    private var groupedProjects: [(title: String, projects: [Project])] {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

        var today: [Project] = []
        var thisWeek: [Project] = []
        var older: [Project] = []

        for project in filteredProjects {
            let date = project.lastActiveAt ?? project.createdAt
            if date >= startOfToday {
                today.append(project)
            } else if date >= startOfWeek {
                thisWeek.append(project)
            } else {
                older.append(project)
            }
        }

        var groups: [(title: String, projects: [Project])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !older.isEmpty { groups.append(("Older", older)) }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .lineLimit(3)
                    Spacer()
                    Button(action: { self.errorMessage = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                }
                .foregroundColor(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }

            if store.projects.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("No projects yet")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("\u{2318}\u{21E7}O to add one")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if groupedProjects.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groupedProjects, id: \.title) { group in
                            Text(group.title.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                                .padding(.horizontal, 14)
                                .padding(.top, 12)
                                .padding(.bottom, 4)

                            ForEach(group.projects) { project in
                                ProjectSection(
                                    project: project,
                                    workspaces: store.workspaces(for: project.id),
                                    activeWorkspaceID: store.activeProjectID == project.id ? store.activeWorkspaceID : nil,
                                    onSelectProject: { selectProject(project) },
                                    onSelectWorkspace: { selectWorkspace($0) },
                                    onCreateWorkspaceFromDefault: { createWorkspace(for: project, branch: project.defaultBranch) },
                                    onCreateWorkspaceFromBranch: { createWorkspace(for: project, branch: $0) },
                                    onDeleteWorkspace: { deleteWorkspace($0) },
                                    onMergeWorkspace: { mergeWorkspace($0, projectPath: project.path) },
                                    onRemoveProject: { store.removeProject(id: project.id) },
                                    onRenameWorkspace: { renameWorkspace($0, to: $1) }
                                )
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)

            // Search — above Add Project
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                TextField("Search projects...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
            }

            // Bottom: + Add Project
            Button(action: addProject) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("Add Project")
                        .font(.system(size: 12))
                }
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
            }
        }
        .padding(.top, 38)
        .background(.clear)
    }

    // MARK: - Actions

    private func addProject() {
        NotificationCenter.default.post(name: .openProjectRequested, object: nil)
    }

    private func selectProject(_ project: Project) {
        store.activeProjectID = project.id
        store.activeWorkspaceID = nil
    }

    private func selectWorkspace(_ workspace: Workspace) {
        store.activeProjectID = workspace.projectID
        store.activeWorkspaceID = workspace.id
    }

    private func createWorkspace(for project: Project, branch: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let workspace = try WorkspaceCloner.createWorkspace(
                    projectID: project.id,
                    projectName: project.name,
                    projectPath: project.path,
                    parentBranch: branch
                )
                DispatchQueue.main.async {
                    store.addWorkspace(workspace)
                    store.activeProjectID = project.id
                    store.activeWorkspaceID = workspace.id
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        WorkspaceCloner.deleteWorkspace(workspace)
        store.deleteWorkspace(id: workspace.id)
    }

    private func mergeWorkspace(_ workspace: Workspace, projectPath: String) {
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let message = try WorkspaceCloner.mergeWorkspaceIntoProject(workspace, projectPath: projectPath)
                DispatchQueue.main.async {
                    store.updateWorkspaceStatus(id: workspace.id, status: .merged)
                    store.requestGitRefresh()
                    // Clear any previous error
                    errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func renameWorkspace(_ workspace: Workspace, to newName: String) {
        guard let index = store.workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        store.workspaces[index].name = newName
        ForgeStore.shared.saveProjectData(projects: store.projects, workspaces: store.workspaces)
    }
}

// MARK: - Project Section

private struct ProjectSection: View {
    let project: Project
    let workspaces: [Workspace]
    let activeWorkspaceID: UUID?
    let onSelectProject: () -> Void
    let onSelectWorkspace: (Workspace) -> Void
    let onCreateWorkspaceFromDefault: () -> Void
    let onCreateWorkspaceFromBranch: (String) -> Void
    let onDeleteWorkspace: (Workspace) -> Void
    let onMergeWorkspace: (Workspace) -> Void
    let onRemoveProject: () -> Void
    let onRenameWorkspace: (Workspace, String) -> Void

    @State private var expanded: Bool
    @State private var branches: [String] = []
    @State private var isHovered = false

    private var isProjectActive: Bool {
        ProjectStore.shared.activeProjectID == project.id && ProjectStore.shared.activeWorkspaceID == nil
    }

    init(
        project: Project,
        workspaces: [Workspace],
        activeWorkspaceID: UUID?,
        onSelectProject: @escaping () -> Void,
        onSelectWorkspace: @escaping (Workspace) -> Void,
        onCreateWorkspaceFromDefault: @escaping () -> Void,
        onCreateWorkspaceFromBranch: @escaping (String) -> Void,
        onDeleteWorkspace: @escaping (Workspace) -> Void,
        onMergeWorkspace: @escaping (Workspace) -> Void,
        onRemoveProject: @escaping () -> Void,
        onRenameWorkspace: @escaping (Workspace, String) -> Void
    ) {
        self.project = project
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.onSelectProject = onSelectProject
        self.onSelectWorkspace = onSelectWorkspace
        self.onCreateWorkspaceFromDefault = onCreateWorkspaceFromDefault
        self.onCreateWorkspaceFromBranch = onCreateWorkspaceFromBranch
        self.onDeleteWorkspace = onDeleteWorkspace
        self.onMergeWorkspace = onMergeWorkspace
        self.onRemoveProject = onRemoveProject
        self.onRenameWorkspace = onRenameWorkspace
        let state = ForgeStore.shared.loadStateFields()
        _expanded = State(initialValue: !state.collapsedProjects.contains(project.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project row
            HStack(spacing: 0) {
                if !workspaces.isEmpty {
                    Button(action: { withAnimation(.easeInOut(duration: 0.12)) { toggleExpanded() } }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 28)
                } else {
                    Spacer().frame(width: 24)
                }

                Text(project.name)
                    .font(.system(size: 13))
                    .foregroundColor(
                        isProjectActive
                            ? .white
                            : Color(nsColor: .labelColor)
                    )
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if workspaces.isEmpty {
                            onSelectProject()
                        } else {
                            withAnimation(.easeInOut(duration: 0.12)) { toggleExpanded() }
                        }
                    }

                Spacer(minLength: 8)

                // Arrow to open project terminal (only when workspaces exist)
                if !workspaces.isEmpty {
                    Button(action: onSelectProject) {
                        Image(systemName: "arrow.right.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open project terminal")
                    .opacity(isHovered ? 1 : 0)
                }

                // + creates workspace from default branch
                Button(action: onCreateWorkspaceFromDefault) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New workspace from \(project.defaultBranch)")
                .opacity(isHovered ? 1 : 0)

                // ... menu
                Menu {
                    Menu("From branch") {
                        if branches.isEmpty {
                            Text("Loading...")
                        } else {
                            ForEach(branches, id: \.self) { branch in
                                Button(branch) {
                                    onCreateWorkspaceFromBranch(branch)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Remove Project", role: .destructive) { onRemoveProject() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                        .frame(width: 24, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .opacity(isHovered ? 1 : 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(
                isProjectActive
                    ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2)))
                    : nil
            )
            .onHover { isHovered = $0 }

            // Workspaces
            if expanded {
                ForEach(workspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        isActive: activeWorkspaceID == workspace.id,
                        onSelect: { onSelectWorkspace(workspace) },
                        onMerge: { onMergeWorkspace(workspace) },
                        onDelete: { onDeleteWorkspace(workspace) },
                        onRename: { onRenameWorkspace(workspace, $0) }
                    )
                }
            }
        }
        .padding(.bottom, 4)
        .onAppear { loadBranches() }
    }

    private func toggleExpanded() {
        expanded.toggle()
        ForgeStore.shared.updateStateFields { state in
            if expanded {
                state.collapsedProjects.remove(project.id)
            } else {
                state.collapsedProjects.insert(project.id)
            }
        }
    }

    private func loadBranches() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Git.shared.run(in: project.path, args: ["branch", "--list", "--format=%(refname:short)"])
            guard result.success else { return }
            let parsed = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .sorted()
            DispatchQueue.main.async {
                branches = parsed
            }
        }
    }
}

// MARK: - Workspace Row

private struct WorkspaceRow: View {
    let workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onMerge: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @ObservedObject private var notificationStore = NotificationStore.shared
    @ObservedObject private var summaryStore = SummaryStore.shared
    @State private var isEditing = false
    @State private var editName = ""

    /// Aggregate agent status across all tabs in this workspace
    private var workspaceAgentStatus: AgentStatus {
        let tabIDs = TerminalSessionManager.shared.tabs
            .filter { $0.workspaceID == workspace.id }
            .map(\.id)
        for id in tabIDs {
            if notificationStore.agentStatusByTab[id] == .waitingForInput { return .waitingForInput }
            if notificationStore.agentStatusByTab[id] == .running { return .running }
        }
        return .idle
    }

    /// Total unread notifications across all tabs in this workspace
    private var workspaceUnreadCount: Int {
        let tabIDs = TerminalSessionManager.shared.tabs
            .filter { $0.workspaceID == workspace.id }
            .map(\.id)
        return tabIDs.reduce(0) { $0 + (notificationStore.unreadCountByTab[$1] ?? 0) }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                if isEditing {
                    TextField("Name", text: $editName, onCommit: {
                        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onRename(trimmed) }
                        isEditing = false
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.leading, 34)
                } else {
                    HStack(spacing: 5) {
                        Text(workspace.name)
                            .font(.system(size: 13))
                            .foregroundColor(
                                workspace.status == .merged
                                    ? Color(nsColor: .tertiaryLabelColor)
                                    : isActive ? .primary : Color(nsColor: .secondaryLabelColor)
                            )
                            .lineLimit(1)
                            .strikethrough(workspace.status == .merged, color: Color(nsColor: .tertiaryLabelColor))
                            .opacity(workspaceAgentStatus == .running ? 1.0 : 1.0)
                        Spacer()

                        if workspace.status == .merged {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.green.opacity(0.6))
                        }

                        // Status dot — last state wins: blue notification > orange waiting > green running
                        if workspaceUnreadCount > 0 {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 6, height: 6)
                        } else if workspaceAgentStatus == .waitingForInput {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                        } else if workspaceAgentStatus == .running {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                                .modifier(PulseModifier())
                        }
                    }
                    .padding(.leading, 34)

                    if let summary = summaryStore.summaryByWorkspace[workspace.id] {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 34)
                            .padding(.top, 1)
                            .help(summary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                isActive
                    ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2)))
                    : nil
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if workspace.status == .active {
                Button("Merge into Project") { onMerge() }
            }
            Button("Rename") {
                editName = workspace.name
                isEditing = true
            }
            Divider()
            Button("Delete Workspace", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Pulse Animation Modifier

private struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

extension Notification.Name {
    static let openProjectRequested = Notification.Name("openProjectRequested")
}
