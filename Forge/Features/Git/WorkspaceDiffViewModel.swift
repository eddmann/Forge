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
    private var cancellables = Set<AnyCancellable>()

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

        let parentBranch = workspace.parentBranch

        // Check if HEAD has changed — skip redundant work
        let headResult = Git.shared.run(in: repoPath, args: ["rev-parse", "HEAD"])
        let currentHead = headResult.trimmedOutput
        if headResult.success, currentHead == lastHeadSHA, !fileDiffs.isEmpty {
            return
        }

        isLoading = fileDiffs.isEmpty
        error = nil

        // Find merge-base
        Git.shared.runAsync(in: repoPath, args: ["merge-base", parentBranch, "HEAD"]) { [weak self] mergeBaseResult in
            Task { @MainActor in
                guard let self else { return }

                guard mergeBaseResult.success else {
                    self.isLoading = false
                    self.error = "Could not find common ancestor with '\(parentBranch)'"
                    return
                }

                let mergeBase = mergeBaseResult.trimmedOutput
                self.loadDiffs(repoPath: repoPath, mergeBase: mergeBase)
                self.loadCommits(repoPath: repoPath, parentBranch: parentBranch, currentHead: currentHead)
            }
        }
    }

    // MARK: - Load Diffs

    private func loadDiffs(repoPath: String, mergeBase: String) {
        diffService.diffAsync(in: repoPath, request: .between(mergeBase, "HEAD")) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
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

    private func loadCommits(repoPath: String, parentBranch: String, currentHead: String) {
        Git.shared.runAsync(
            in: repoPath,
            args: ["log", "\(parentBranch)..HEAD", "--format=%H%n%s%n%an%n%aI", "--reverse"]
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if result.success {
                    self.commits = WorkspaceCommit.parse(from: result.trimmedOutput)
                    self.lastHeadSHA = currentHead
                }
            }
        }
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
        let mergeBaseResult = Git.shared.run(in: repoPath, args: ["merge-base", workspace.parentBranch, "HEAD"])
        guard mergeBaseResult.success else { return }

        let mergeBase = mergeBaseResult.trimmedOutput
        TerminalSessionManager.shared.openWorkspaceDiffTab(
            repoPath: repoPath,
            baseRef: mergeBase,
            scrollToFile: filePath
        )
    }
}
