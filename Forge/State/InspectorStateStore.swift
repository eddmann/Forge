import Combine
import Foundation

// MARK: - Per-Workspace Inspector State

/// Cached inspector UI state for a single workspace (or the bare-project scope).
struct InspectorWorkspaceState {
    var commandsExpanded = false
    var processesExpanded = false
    var activeTab: String = "Pending"
    var commitMessage = ""
    var isAmend = false

    // Cached git status so switching back doesn't flash blank
    var statuses: [FileStatus] = []
    var grouped: [WorkingTreeGroup: [FileStatus]] = [:]
    var currentBranch: String?
    var ahead = 0
    var behind = 0
    var hasUpstream = false
    var lastCommitMessage: String?
}

// MARK: - Codable entry for persistence

struct InspectorStateEntry: Codable {
    var commandsExpanded: Bool = false
    var processesExpanded: Bool = false
    var activeTab: String = "Pending"
    var commitMessage: String = ""
    var isAmend: Bool = false
}

// MARK: - Store

@MainActor
final class InspectorStateStore: ObservableObject {
    static let shared = InspectorStateStore()

    /// In-memory per-workspace state keyed by scope key (same format as terminal scopes).
    private var cache: [String: InspectorWorkspaceState] = [:]

    /// Published trigger so views can observe changes.
    @Published private(set) var revision = 0

    private func scopeKey(projectID: UUID?, workspaceID: UUID?) -> String {
        "\(projectID?.uuidString ?? "")|\(workspaceID?.uuidString ?? "")"
    }

    private var currentKey: String {
        scopeKey(
            projectID: ProjectStore.shared.activeProjectID,
            workspaceID: ProjectStore.shared.activeWorkspaceID
        )
    }

    // MARK: - Access

    var current: InspectorWorkspaceState {
        get { cache[currentKey] ?? InspectorWorkspaceState() }
        set {
            cache[currentKey] = newValue
            revision += 1
        }
    }

    subscript(projectID: UUID?, workspaceID: UUID?) -> InspectorWorkspaceState {
        get { cache[scopeKey(projectID: projectID, workspaceID: workspaceID)] ?? InspectorWorkspaceState() }
        set { cache[scopeKey(projectID: projectID, workspaceID: workspaceID)] = newValue }
    }

    // MARK: - Convenience mutators

    func update(_ transform: (inout InspectorWorkspaceState) -> Void) {
        var state = current
        transform(&state)
        current = state
    }

    // MARK: - Persistence

    func persist() {
        var entries: [String: InspectorStateEntry] = [:]
        for (key, state) in cache {
            entries[key] = InspectorStateEntry(
                commandsExpanded: state.commandsExpanded,
                processesExpanded: state.processesExpanded,
                activeTab: state.activeTab,
                commitMessage: state.commitMessage,
                isAmend: state.isAmend
            )
        }
        ForgeStore.shared.updateStateFields { file in
            file.inspectorStates = entries
        }
    }

    func restore() {
        let state = ForgeStore.shared.loadStateFields()
        for (key, entry) in state.inspectorStates {
            var ws = InspectorWorkspaceState()
            ws.commandsExpanded = entry.commandsExpanded
            ws.processesExpanded = entry.processesExpanded
            ws.activeTab = entry.activeTab
            ws.commitMessage = entry.commitMessage
            ws.isAmend = entry.isAmend
            cache[key] = ws
        }
    }

    // MARK: - Cleanup

    func removeState(forWorkspaceID id: UUID) {
        let suffix = "|\(id.uuidString)"
        for key in cache.keys where key.hasSuffix(suffix) {
            cache.removeValue(forKey: key)
        }
    }
}
