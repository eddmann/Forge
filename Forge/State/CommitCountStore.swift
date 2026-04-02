import Combine
import Foundation

/// Tracks how many commits each workspace branch is ahead of its parent branch.
/// Used by the sidebar to show an "↑N" indicator on workspace rows.
@MainActor
class CommitCountStore: ObservableObject {
    static let shared = CommitCountStore()

    @Published private(set) var countByWorkspace: [UUID: Int] = [:]

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Refresh counts when the workspace list changes
        ProjectStore.shared.$workspaces
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAll() }
            .store(in: &cancellables)

        // Also refresh when git status changes (new commits)
        StatusViewModel.shared.$ahead
            .dropFirst()
            .sink { [weak self] _ in self?.refreshAll() }
            .store(in: &cancellables)

        refreshAll()
    }

    func refreshAll() {
        let workspaces = ProjectStore.shared.workspaces.filter { $0.status == .active }
        for workspace in workspaces {
            refreshCount(for: workspace)
        }
        // Clean up removed workspaces
        let activeIDs = Set(workspaces.map(\.id))
        for key in countByWorkspace.keys where !activeIDs.contains(key) {
            countByWorkspace.removeValue(forKey: key)
        }
    }

    private func refreshCount(for workspace: Workspace) {
        let path = workspace.path
        let parentBranch = workspace.parentBranch
        let wsID = workspace.id

        DispatchQueue.global(qos: .utility).async {
            let result = Git.shared.run(in: path, args: ["rev-list", "--count", "\(parentBranch)..HEAD"])
            guard result.success, let count = Int(result.trimmedOutput) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.countByWorkspace[wsID] = count
            }
        }
    }
}
