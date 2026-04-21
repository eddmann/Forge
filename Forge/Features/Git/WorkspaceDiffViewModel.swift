import Combine
import Foundation

/// ViewModel for the Workspace tab — shows cumulative changes and commits
/// on the workspace branch relative to its parent branch.
@MainActor
final class WorkspaceDiffViewModel: ObservableObject {
    static let shared = WorkspaceDiffViewModel()

    // MARK: - Published State

    @Published var fileDiffs: [GitFileDiff] = []
    @Published var commits: [WorkspaceCommit] = []
    @Published var stats: GitDiffStats?
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Private

    private let diffService = GitDiffService.shared
    private var refreshTimer: Timer?
    private var lastHeadSHA: String?
    private var refreshGeneration = 0
    private var lastFetchAtByRepo: [String: Date] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let fetchThrottleInterval: TimeInterval = 60

    private var workspace: Workspace? {
        ProjectStore.shared.activeWorkspace
    }

    private var repoPath: String? {
        ProjectStore.shared.effectiveRootPath
    }

    private init() {
        ProjectStore.shared.$activeWorkspaceID
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.lastHeadSHA = nil
                    self?.refresh()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Auto Refresh

    func startAutoRefresh(interval: TimeInterval = 10.0) {
        stopAutoRefresh()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Refresh

    func refresh() {
        guard let repoPath, let workspace, workspace.status == .active else {
            fileDiffs = []
            commits = []
            stats = nil
            isLoading = false
            error = nil
            return
        }

        // Scratch projects have no remote / parent branch — show empty state.
        if workspace.isScratch {
            fileDiffs = []
            commits = []
            stats = nil
            isLoading = false
            error = nil
            return
        }

        let parentRef = "origin/\(workspace.parentBranch)"
        let workspaceID = workspace.id
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = fileDiffs.isEmpty
        error = nil

        Git.shared.runAsync(in: repoPath, args: ["rev-parse", "HEAD"]) { [weak self] headResult in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentRefresh(generation, repoPath: repoPath, workspaceID: workspaceID) else { return }

                guard headResult.success else {
                    self.isLoading = false
                    self.error = headResult.trimmedOutput
                    return
                }

                let currentHead = headResult.trimmedOutput
                if currentHead == self.lastHeadSHA, !self.fileDiffs.isEmpty {
                    self.isLoading = false
                    return
                }

                self.loadWorkspaceDiff(
                    repoPath: repoPath,
                    parentRef: parentRef,
                    currentHead: currentHead,
                    workspaceID: workspaceID,
                    generation: generation
                )
            }
        }
    }

    private func loadWorkspaceDiff(
        repoPath: String,
        parentRef: String,
        currentHead: String,
        workspaceID: UUID,
        generation: Int
    ) {
        let continueLoading = { [weak self] in
            Git.shared.runAsync(in: repoPath, args: ["merge-base", parentRef, "HEAD"]) { mergeBaseResult in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isCurrentRefresh(generation, repoPath: repoPath, workspaceID: workspaceID) else { return }

                    guard mergeBaseResult.success else {
                        self.isLoading = false
                        self.error = "Could not find common ancestor with '\(parentRef)'"
                        return
                    }

                    let mergeBase = mergeBaseResult.trimmedOutput
                    self.loadDiffs(
                        repoPath: repoPath,
                        mergeBase: mergeBase,
                        workspaceID: workspaceID,
                        generation: generation
                    )
                    self.loadCommits(
                        repoPath: repoPath,
                        parentRef: parentRef,
                        currentHead: currentHead,
                        workspaceID: workspaceID,
                        generation: generation
                    )
                }
            }
        }

        if shouldFetch(repoPath: repoPath) {
            lastFetchAtByRepo[repoPath] = Date()
            Git.shared.runAsync(in: repoPath, args: ["fetch", "origin", "--no-tags"]) { _ in
                continueLoading()
            }
            return
        }

        continueLoading()
    }

    // MARK: - Load Diffs

    private func loadDiffs(
        repoPath: String,
        mergeBase: String,
        workspaceID: UUID,
        generation: Int
    ) {
        diffService.diffAsync(in: repoPath, request: .between(mergeBase, "HEAD")) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentRefresh(generation, repoPath: repoPath, workspaceID: workspaceID) else { return }
                self.isLoading = false

                switch result {
                case let .success(diffResult):
                    self.fileDiffs = diffResult.files
                    self.stats = diffResult.stats
                case let .failure(err):
                    self.error = err.localizedDescription
                }
            }
        }
    }

    // MARK: - Load Commits

    private func loadCommits(
        repoPath: String,
        parentRef: String,
        currentHead: String,
        workspaceID: UUID,
        generation: Int
    ) {
        Git.shared.runAsync(
            in: repoPath,
            args: ["log", "\(parentRef)..HEAD", "--format=%H%n%s%n%an%n%aI", "--reverse"]
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentRefresh(generation, repoPath: repoPath, workspaceID: workspaceID) else { return }
                if result.success {
                    self.commits = WorkspaceCommit.parse(from: result.trimmedOutput)
                    self.lastHeadSHA = currentHead
                }
            }
        }
    }

    private func shouldFetch(repoPath: String) -> Bool {
        guard let lastFetchAt = lastFetchAtByRepo[repoPath] else { return true }
        return Date().timeIntervalSince(lastFetchAt) >= fetchThrottleInterval
    }

    private func isCurrentRefresh(_ generation: Int, repoPath: String, workspaceID: UUID) -> Bool {
        generation == refreshGeneration
            && self.repoPath == repoPath
            && workspace?.id == workspaceID
    }

    #if DEBUG
        func setDemo(commits demoCommits: [WorkspaceCommit], fileDiffs demoFileDiffs: [GitFileDiff]) {
            commits = demoCommits
            fileDiffs = demoFileDiffs
            stats = GitDiffStats(
                filesChanged: demoFileDiffs.count,
                insertions: demoFileDiffs.reduce(0) { $0 + $1.additions },
                deletions: demoFileDiffs.reduce(0) { $0 + $1.deletions }
            )
            isLoading = false
            error = nil
        }
    #endif

    // MARK: - File Selection

    func selectFile(_ filePath: String) {
        guard let repoPath, let workspace else { return }

        // Find merge-base for the center panel diff
        let mergeBaseResult = Git.shared.run(in: repoPath, args: ["merge-base", "origin/\(workspace.parentBranch)", "HEAD"])
        guard mergeBaseResult.success else { return }

        let mergeBase = mergeBaseResult.trimmedOutput
        TerminalSessionManager.shared.openWorkspaceDiffTab(
            repoPath: repoPath,
            baseRef: mergeBase,
            scrollToFile: filePath
        )
    }
}
