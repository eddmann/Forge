import Combine
import Foundation

/// Tracks how many commits each workspace branch is ahead of its parent branch.
/// Used by the sidebar to show an "↑N" indicator on workspace rows.
@MainActor
class CommitCountStore: ObservableObject {
    static let shared = CommitCountStore()

    private struct WorkspaceSnapshot: Equatable {
        let path: String
        let parentBranch: String
        let status: Workspace.Status
        let isScratch: Bool
    }

    @Published private(set) var countByWorkspace: [UUID: Int] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var trackedWorkspaces: [UUID: WorkspaceSnapshot] = [:]
    private var inFlightWorkspaceIDs: Set<UUID> = []
    private let refreshQueue = DispatchQueue(label: "forge.commit-count-refresh", qos: .utility)

    private init() {
        // Refresh counts when the workspace list changes, but only for changed workspaces.
        ProjectStore.shared.$workspaces
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] workspaces in self?.syncWorkspaces(workspaces) }
            .store(in: &cancellables)

        // Refresh the selected workspace's count when the user switches scope.
        ProjectStore.shared.$activeWorkspaceID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshActiveWorkspace() }
            .store(in: &cancellables)

        // Recompute the selected workspace count when the active repo head changes.
        RepoGitStateStore.shared.$activeSnapshot
            .dropFirst()
            .compactMap { $0?.headSHA }
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshActiveWorkspace() }
            .store(in: &cancellables)
    }

    private func syncWorkspaces(_ workspaces: [Workspace]) {
        let activeWorkspaces = workspaces.filter { $0.status == .active }
        let activeIDs = Set(activeWorkspaces.map(\.id))

        for key in countByWorkspace.keys where !activeIDs.contains(key) {
            countByWorkspace.removeValue(forKey: key)
        }
        trackedWorkspaces = trackedWorkspaces.filter { activeIDs.contains($0.key) }
        inFlightWorkspaceIDs.formIntersection(activeIDs)

        for workspace in activeWorkspaces {
            let snapshot = snapshot(for: workspace)
            let existingSnapshot = trackedWorkspaces[workspace.id]
            trackedWorkspaces[workspace.id] = snapshot
            if existingSnapshot != snapshot || countByWorkspace[workspace.id] == nil {
                refreshCount(for: workspace, snapshot: snapshot)
            }
        }
    }

    private func refreshActiveWorkspace() {
        guard let workspace = ProjectStore.shared.activeWorkspace, workspace.status == .active else { return }
        let snapshot = snapshot(for: workspace)
        trackedWorkspaces[workspace.id] = snapshot
        refreshCount(for: workspace, snapshot: snapshot)
    }

    private func snapshot(for workspace: Workspace) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            path: workspace.path,
            parentBranch: workspace.parentBranch,
            status: workspace.status,
            isScratch: workspace.isScratch
        )
    }

    private func refreshCount(for workspace: Workspace, snapshot: WorkspaceSnapshot) {
        // Scratch projects have no remote / parent branch — short-circuit.
        if snapshot.isScratch {
            countByWorkspace[workspace.id] = 0
            return
        }

        let wsID = workspace.id
        guard !inFlightWorkspaceIDs.contains(wsID) else { return }
        inFlightWorkspaceIDs.insert(wsID)

        refreshQueue.async {
            let result = Git.shared.run(in: snapshot.path, args: ["rev-list", "--count", "origin/\(snapshot.parentBranch)..HEAD"])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                inFlightWorkspaceIDs.remove(wsID)
                guard trackedWorkspaces[wsID] == snapshot else { return }
                guard result.success, let count = Int(result.trimmedOutput) else { return }
                countByWorkspace[wsID] = count
            }
        }
    }
}
