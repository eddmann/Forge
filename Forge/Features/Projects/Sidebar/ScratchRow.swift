import SwiftUI

struct ScratchRow: View {
    let scratch: Project
    let workspace: Workspace
    let isActive: Bool
    let isDeleting: Bool
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @ObservedObject private var agentEventStore = AgentEventStore.shared
    @ObservedObject private var summaryStore = SummaryStore.shared

    @State private var isEditing = false
    @State private var editName = ""
    @State private var showDeleteConfirmation = false
    @State private var isHovered = false

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
                    .padding(.leading, 8)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "scribble")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .frame(width: 14)
                        Text(scratch.name)
                            .font(.system(size: 13))
                            .foregroundColor(isActive ? .primary : Color(nsColor: .secondaryLabelColor))
                            .lineLimit(1)
                        Spacer()

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
                    .padding(.leading, 8)

                    if let summary = summaryStore.summaryByWorkspace[workspace.id] {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 26)
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
        .opacity(isDeleting ? 0.4 : 1.0)
        .overlay {
            if isDeleting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Deleting…")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
            }
        }
        .allowsHitTesting(!isDeleting)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button {
                editName = scratch.name
                isEditing = true
            } label: {
                Image(systemName: "pencil")
                Text("Rename")
            }
            Button {
                NotificationCenter.default.post(
                    name: .promoteScratchRequested,
                    object: scratch.id
                )
            } label: {
                Image(systemName: "arrow.up.right.square")
                Text("Promote…")
            }
            Divider()
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Image(systemName: "trash")
                Text("Delete Scratch")
            }
        }
        .confirmationDialog(
            "Delete \(scratch.name)?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete") { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the scratch directory from disk.")
        }
    }
}

extension Notification.Name {
    static let newScratchRequested = Notification.Name("newScratchRequested")
    static let promoteScratchRequested = Notification.Name("promoteScratchRequested")
}
