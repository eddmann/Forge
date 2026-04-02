import SwiftUI

private struct ScopeActivity {
    let status: AgentActivity
    let sessionCount: Int
}

struct ProjectListView: View {
    @ObservedObject private var store = ProjectStore.shared
    @ObservedObject private var sessionManager = TerminalSessionManager.shared
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var creatingWorkspaceForProject: Set<UUID> = []
    @State private var deletingWorkspaceIDs: Set<UUID> = []
    @State private var mergingWorkspaceIDs: Set<UUID> = []

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
                                    isCreatingWorkspace: creatingWorkspaceForProject.contains(project.id),
                                    deletingWorkspaceIDs: deletingWorkspaceIDs,
                                    mergingWorkspaceIDs: mergingWorkspaceIDs,
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
        creatingWorkspaceForProject.insert(project.id)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let workspace = try WorkspaceCloner.createWorkspace(
                    projectID: project.id,
                    projectName: project.name,
                    projectPath: project.path,
                    parentBranch: branch
                )
                DispatchQueue.main.async {
                    creatingWorkspaceForProject.remove(project.id)
                    store.addWorkspace(workspace)
                    store.activeProjectID = project.id
                    store.activeWorkspaceID = workspace.id
                }
            } catch {
                DispatchQueue.main.async {
                    creatingWorkspaceForProject.remove(project.id)
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteWorkspace(_ workspace: Workspace) {
        deletingWorkspaceIDs.insert(workspace.id)
        DispatchQueue.global(qos: .userInitiated).async {
            WorkspaceCloner.deleteWorkspace(workspace)
            DispatchQueue.main.async {
                deletingWorkspaceIDs.remove(workspace.id)
                store.deleteWorkspace(id: workspace.id)
            }
        }
    }

    private func mergeWorkspace(_ workspace: Workspace, projectPath: String) {
        errorMessage = nil
        mergingWorkspaceIDs.insert(workspace.id)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let message = try WorkspaceCloner.mergeWorkspaceIntoProject(workspace, projectPath: projectPath)
                DispatchQueue.main.async {
                    mergingWorkspaceIDs.remove(workspace.id)
                    store.updateWorkspaceStatus(id: workspace.id, status: .merged)
                    store.recordActivity(for: workspace.projectID)
                    store.requestGitRefresh()
                    // Clear any previous error
                    errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async {
                    mergingWorkspaceIDs.remove(workspace.id)
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
    let isCreatingWorkspace: Bool
    let deletingWorkspaceIDs: Set<UUID>
    let mergingWorkspaceIDs: Set<UUID>
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
    @State private var showRemoveConfirmation = false

    private var isProjectActive: Bool {
        ProjectStore.shared.activeProjectID == project.id && ProjectStore.shared.activeWorkspaceID == nil
    }

    init(
        project: Project,
        workspaces: [Workspace],
        activeWorkspaceID: UUID?,
        isCreatingWorkspace: Bool,
        deletingWorkspaceIDs: Set<UUID>,
        mergingWorkspaceIDs: Set<UUID>,
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
        self.isCreatingWorkspace = isCreatingWorkspace
        self.deletingWorkspaceIDs = deletingWorkspaceIDs
        self.mergingWorkspaceIDs = mergingWorkspaceIDs
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
                HStack(spacing: 0) {
                    if !workspaces.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
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

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if workspaces.isEmpty {
                        onSelectProject()
                    } else {
                        withAnimation(.easeInOut(duration: 0.12)) { toggleExpanded() }
                    }
                }

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
                .disabled(isCreatingWorkspace)

                // ... menu
                Menu {
                    Menu {
                        if branches.isEmpty {
                            Text("Loading...")
                        } else {
                            ForEach(branches, id: \.self) { branch in
                                Button(branch) {
                                    onCreateWorkspaceFromBranch(branch)
                                }
                                .disabled(isCreatingWorkspace)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.branch")
                        Text("From branch")
                    }
                    Divider()
                    Button(role: .destructive) { showRemoveConfirmation = true } label: {
                        Image(systemName: "trash")
                        Text("Remove Project")
                    }
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
            if expanded || isCreatingWorkspace {
                ForEach(workspaces) { workspace in
                    WorkspaceRow(
                        workspace: workspace,
                        isActive: activeWorkspaceID == workspace.id,
                        isDeleting: deletingWorkspaceIDs.contains(workspace.id),
                        isMerging: mergingWorkspaceIDs.contains(workspace.id),
                        onSelect: { onSelectWorkspace(workspace) },
                        onMerge: { onMergeWorkspace(workspace) },
                        onDelete: { onDeleteWorkspace(workspace) },
                        onRename: { onRenameWorkspace(workspace, $0) }
                    )
                }

                if isCreatingWorkspace {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Creating workspace…")
                            .font(.system(size: 13))
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                    .padding(.leading, 34)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                }
            }
        }
        .padding(.bottom, 4)
        .onAppear { loadBranches() }
        .confirmationDialog(
            "Remove \(project.name)?",
            isPresented: $showRemoveConfirmation
        ) {
            Button("Remove") { onRemoveProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the project and delete all its workspaces from disk.")
        }
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
    let isDeleting: Bool
    let isMerging: Bool
    let onSelect: () -> Void
    let onMerge: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void

    @ObservedObject private var agentEventStore = AgentEventStore.shared
    @ObservedObject private var summaryStore = SummaryStore.shared
    @ObservedObject private var commitCountStore = CommitCountStore.shared
    @State private var isEditing = false
    @State private var editName = ""
    @State private var showDeleteConfirmation = false

    /// Aggregate agent activity across all tabs in this workspace
    private var workspaceAgentStatus: AgentActivity {
        let tabIDs = TerminalSessionManager.shared.tabs
            .filter { $0.workspaceID == workspace.id }
            .map(\.id)
        for id in tabIDs {
            if agentEventStore.activityByTab[id] == .waitingForPermission { return .waitingForPermission }
            if agentEventStore.activityByTab[id] == .toolExecuting { return .toolExecuting }
            if agentEventStore.activityByTab[id] == .thinking { return .thinking }
            if agentEventStore.activityByTab[id] == .retrying { return .retrying }
            if agentEventStore.activityByTab[id] == .compacting { return .compacting }
        }
        return .idle
    }

    /// Total unread notifications across all tabs in this workspace
    private var workspaceUnreadCount: Int {
        let tabIDs = TerminalSessionManager.shared.tabs
            .filter { $0.workspaceID == workspace.id }
            .map(\.id)
        return tabIDs.reduce(0) { $0 + (agentEventStore.unreadCountByTab[$1] ?? 0) }
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
                            .opacity(workspaceAgentStatus == .toolExecuting ? 1.0 : 1.0)
                        Spacer()

                        // Commit count ahead of parent branch
                        if let count = commitCountStore.countByWorkspace[workspace.id], count > 0,
                           workspace.status != .merged
                        {
                            HStack(spacing: 1) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 8, weight: .bold))
                                Text("\(count)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        }

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
                        } else if workspaceAgentStatus == .waitingForPermission {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                        } else if workspaceAgentStatus == .thinking
                            || workspaceAgentStatus == .toolExecuting
                            || workspaceAgentStatus == .retrying
                            || workspaceAgentStatus == .compacting
                        {
                            AgentStatusDot(activity: workspaceAgentStatus)
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
        .opacity(isDeleting || isMerging ? 0.4 : 1.0)
        .overlay {
            if isDeleting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Deleting…")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
            } else if isMerging {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Merging…")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
            }
        }
        .allowsHitTesting(!isDeleting && !isMerging)
        .contextMenu {
            if workspace.status == .active {
                Button { onMerge() } label: {
                    Image(systemName: "arrow.triangle.merge")
                    Text("Merge into Project")
                }
            }
            Button {
                editName = workspace.name
                isEditing = true
            } label: {
                Image(systemName: "pencil")
                Text("Rename")
            }
            Divider()
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Image(systemName: "trash")
                Text("Delete Workspace")
            }
        }
        .confirmationDialog(
            "Delete \(workspace.name)?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete") { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the workspace directory from disk.")
        }
    }
}

extension Notification.Name {
    static let openProjectRequested = Notification.Name("openProjectRequested")
}
