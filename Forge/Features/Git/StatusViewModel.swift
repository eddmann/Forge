import Combine
import Foundation
import SwiftUI

struct RepoGitSnapshot {
    let repoPath: String
    let statuses: [FileStatus]
    let grouped: [WorkingTreeGroup: [FileStatus]]
    let currentBranch: String?
    let headSHA: String?
    let lastCommitMessage: String?
    let ahead: Int
    let behind: Int
    let hasUpstream: Bool
}

@MainActor
final class RepoGitStateStore: ObservableObject {
    static let shared = RepoGitStateStore()

    private struct InFlightRefresh {
        let id: UUID
        let task: Task<RepoGitSnapshot, Never>
    }

    @Published private(set) var activeRepoPath: String?
    @Published private(set) var activeSnapshot: RepoGitSnapshot?

    private var snapshotsByRepoPath: [String: RepoGitSnapshot] = [:]
    private var inFlightRefreshes: [String: InFlightRefresh] = [:]
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        ProjectStore.shared.$activeProjectID
            .combineLatest(ProjectStore.shared.$activeWorkspaceID)
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.activateCurrentRepo()
            }
            .store(in: &cancellables)

        ProjectStore.shared.$gitRefreshTrigger
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshActiveRepo(force: true)
            }
            .store(in: &cancellables)
    }

    func startAutoRefresh(interval: TimeInterval = 3.0) {
        stopAutoRefresh()
        activateCurrentRepo()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshActiveRepo()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshActiveRepo(force: Bool = false) {
        guard let repoPath = activeRepoPath ?? currentRepoPath() else {
            activeRepoPath = nil
            activeSnapshot = nil
            return
        }

        if !force, let refresh = inFlightRefreshes[repoPath] {
            applyRefreshTask(refresh, for: repoPath)
            return
        }

        let refresh = InFlightRefresh(
            id: UUID(),
            task: Task.detached(priority: .utility) {
                Self.loadSnapshot(repoPath: repoPath)
            }
        )
        inFlightRefreshes[repoPath] = refresh
        applyRefreshTask(refresh, for: repoPath)
    }

    func snapshot(for repoPath: String) -> RepoGitSnapshot? {
        if activeRepoPath == repoPath, let activeSnapshot {
            return activeSnapshot
        }
        return snapshotsByRepoPath[repoPath]
    }

    private func activateCurrentRepo() {
        guard let repoPath = currentRepoPath() else {
            activeRepoPath = nil
            activeSnapshot = nil
            return
        }
        if activeRepoPath != repoPath {
            // Path changed (workspace/project switch). Don't republish the
            // cached snapshot — it was captured for a different working tree
            // and applying it would clobber the per-workspace state that
            // StatusViewModel restores from InspectorStateStore. Wait for
            // the fresh refresh.
            activeRepoPath = repoPath
            activeSnapshot = nil
        }
        refreshActiveRepo(force: true)
    }

    private func applyRefreshTask(_ refresh: InFlightRefresh, for repoPath: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = await refresh.task.value
            guard inFlightRefreshes[repoPath]?.id == refresh.id else { return }
            inFlightRefreshes.removeValue(forKey: repoPath)
            snapshotsByRepoPath[repoPath] = snapshot
            guard activeRepoPath == repoPath else { return }
            activeSnapshot = snapshot
        }
    }

    private func currentRepoPath() -> String? {
        ProjectStore.shared.effectiveRootPath ?? ProjectStore.shared.activeProject?.path
    }

    private nonisolated static func loadSnapshot(repoPath: String) -> RepoGitSnapshot {
        let statusResult = Git.shared.run(in: repoPath, args: ["status", "--porcelain"])
        let branchResult = Git.shared.run(in: repoPath, args: ["rev-parse", "--abbrev-ref", "HEAD"])
        let headResult = Git.shared.run(in: repoPath, args: ["rev-parse", "HEAD"])
        let lastCommitResult = Git.shared.run(in: repoPath, args: ["log", "-1", "--format=%B"])
        let aheadBehindResult = Git.shared.run(in: repoPath, args: ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])

        let statuses = statusResult.success ? FileStatus.parse(porcelain: statusResult.stdout) : []
        let grouped = FileStatus.categorize(statuses)
        let currentBranch = branchResult.success
            ? branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            : nil
        let headSHA = headResult.success
            ? headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            : nil
        let lastCommitMessage = lastCommitResult.success
            ? lastCommitResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            : nil

        var ahead = 0
        var behind = 0
        var hasUpstream = false
        if aheadBehindResult.success {
            hasUpstream = true
            let parts = aheadBehindResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            ahead = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
            behind = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        }

        return RepoGitSnapshot(
            repoPath: repoPath,
            statuses: statuses,
            grouped: grouped,
            currentBranch: currentBranch,
            headSHA: headSHA,
            lastCommitMessage: lastCommitMessage,
            ahead: ahead,
            behind: behind,
            hasUpstream: hasUpstream
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

@MainActor
final class StatusViewModel: ObservableObject {
    static let shared = StatusViewModel()

    // MARK: - Published State

    @Published var statuses: [FileStatus] = []
    @Published var grouped: [WorkingTreeGroup: [FileStatus]] = [:]
    @Published var isLoading = false
    @Published var commitMessage = ""
    @Published var isAmend = false
    @Published var isBusy = false
    @Published var isCommitting = false
    @Published var lastCommitMessage: String?
    @Published var currentBranch: String?
    @Published var ahead = 0
    @Published var behind = 0
    @Published var hasUpstream = false

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    /// Tracks the previous workspace scope for saving state on switch.
    private var previousProjectID: UUID?
    private var previousWorkspaceID: UUID?
    private var repoPath: String? {
        ProjectStore.shared.effectiveRootPath ?? ProjectStore.shared.activeProject?.path
    }

    private init() {
        previousProjectID = ProjectStore.shared.activeProjectID
        previousWorkspaceID = ProjectStore.shared.activeWorkspaceID

        // Coalesce project/workspace selection changes into a single refresh cycle.
        ProjectStore.shared.$activeProjectID
            .combineLatest(ProjectStore.shared.$activeWorkspaceID)
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] newProjectID, newWorkspaceID in
                Task { @MainActor in
                    guard let self else { return }
                    self.saveToInspectorState(
                        projectID: self.previousProjectID,
                        workspaceID: self.previousWorkspaceID
                    )
                    self.previousProjectID = newProjectID
                    self.previousWorkspaceID = newWorkspaceID
                    self.restoreFromInspectorState()
                }
            }
            .store(in: &cancellables)

        RepoGitStateStore.shared.$activeRepoPath
            .dropFirst()
            .sink { [weak self] repoPath in
                guard repoPath == nil else { return }
                self?.clearRefreshState()
            }
            .store(in: &cancellables)

        RepoGitStateStore.shared.$activeSnapshot
            .compactMap { $0 }
            .sink { [weak self] snapshot in
                self?.apply(snapshot: snapshot)
            }
            .store(in: &cancellables)
    }

    // MARK: - Per-Workspace State

    /// Save current commit-related state into the inspector state cache.
    /// When projectID/workspaceID are provided, saves under that scope (used for outgoing workspace).
    /// Otherwise saves under the current active scope.
    func saveToInspectorState(projectID: UUID? = nil, workspaceID: UUID? = nil) {
        let store = InspectorStateStore.shared
        let useExplicit = projectID != nil || workspaceID != nil
        if useExplicit {
            var state = store[projectID, workspaceID]
            state.commitMessage = commitMessage
            state.isAmend = isAmend
            state.statuses = statuses
            state.grouped = grouped
            state.currentBranch = currentBranch
            state.ahead = ahead
            state.behind = behind
            state.hasUpstream = hasUpstream
            state.lastCommitMessage = lastCommitMessage
            store[projectID, workspaceID] = state
        } else {
            store.update { state in
                state.commitMessage = self.commitMessage
                state.isAmend = self.isAmend
                state.statuses = self.statuses
                state.grouped = self.grouped
                state.currentBranch = self.currentBranch
                state.ahead = self.ahead
                state.behind = self.behind
                state.hasUpstream = self.hasUpstream
                state.lastCommitMessage = self.lastCommitMessage
            }
        }
    }

    /// Restore commit-related state from the inspector state cache for the current workspace.
    func restoreFromInspectorState() {
        let store = InspectorStateStore.shared
        let state = store.current
        commitMessage = state.commitMessage
        isAmend = state.isAmend
        statuses = state.statuses
        grouped = state.grouped
        currentBranch = state.currentBranch
        ahead = state.ahead
        behind = state.behind
        hasUpstream = state.hasUpstream
        lastCommitMessage = state.lastCommitMessage
    }

    // MARK: - Auto Refresh

    func startAutoRefresh(interval: TimeInterval = 3.0) {
        #if DEBUG
            if ProjectStore.shared.isDemo { return }
        #endif
        RepoGitStateStore.shared.startAutoRefresh(interval: interval)
    }

    func stopAutoRefresh() {
        RepoGitStateStore.shared.stopAutoRefresh()
    }

    // MARK: - Refresh

    func refresh() {
        #if DEBUG
            if ProjectStore.shared.isDemo { return }
        #endif
        guard !isBusy else { return }
        RepoGitStateStore.shared.refreshActiveRepo(force: true)
    }

    private func clearRefreshState() {
        statuses = []
        grouped = [:]
        currentBranch = nil
        lastCommitMessage = nil
        ahead = 0
        behind = 0
        hasUpstream = false
        ProjectStore.shared.currentBranch = ""
    }

    private func apply(snapshot: RepoGitSnapshot) {
        let expectedRepoPath = ProjectStore.shared.effectiveRootPath ?? ProjectStore.shared.activeProject?.path
        guard snapshot.repoPath == expectedRepoPath else { return }
        statuses = snapshot.statuses
        grouped = snapshot.grouped
        currentBranch = snapshot.currentBranch
        lastCommitMessage = snapshot.lastCommitMessage
        ahead = snapshot.ahead
        behind = snapshot.behind
        hasUpstream = snapshot.hasUpstream
        ProjectStore.shared.currentBranch = snapshot.currentBranch ?? ""
    }

    // MARK: - Selection

    func selectFile(_ file: FileStatus, staged _: Bool) {
        guard let repoPath else { return }
        TerminalSessionManager.shared.openChangesTab(
            repoPath: repoPath,
            scrollToFile: file.path
        )
    }

    // MARK: - Stage / Unstage

    func stage(file: FileStatus) {
        guard let repoPath else { return }
        runMutating(in: repoPath, args: ["add", "--", file.path]) { [weak self] result in
            guard let self else { return }
            if result.success {
                ToastManager.shared.show("Staged \(file.fileName)")
                recordActivity()
                refresh()
            } else {
                ToastManager.shared.show(cleanError(result.stderr), severity: .error)
            }
        }
    }

    func unstage(file: FileStatus) {
        guard let repoPath else { return }
        runMutating(in: repoPath, args: ["restore", "--staged", "--", file.path]) { [weak self] result in
            guard let self else { return }
            if result.success {
                ToastManager.shared.show("Unstaged \(file.fileName)")
                recordActivity()
                refresh()
            } else {
                ToastManager.shared.show(cleanError(result.stderr), severity: .error)
            }
        }
    }

    func stageAll() {
        guard let repoPath else { return }
        runMutating(in: repoPath, args: ["add", "-A"]) { [weak self] result in
            guard let self else { return }
            if result.success {
                ToastManager.shared.show("Staged all changes")
                recordActivity()
                refresh()
            } else {
                ToastManager.shared.show(cleanError(result.stderr), severity: .error)
            }
        }
    }

    func unstageAll() {
        guard let repoPath else { return }
        runMutating(in: repoPath, args: ["reset", "HEAD"]) { [weak self] result in
            guard let self else { return }
            if result.success {
                ToastManager.shared.show("Unstaged all changes")
                recordActivity()
                refresh()
            } else {
                ToastManager.shared.show(cleanError(result.stderr), severity: .error)
            }
        }
    }

    // MARK: - Discard

    func discard(file: FileStatus, group: WorkingTreeGroup) {
        guard let repoPath else { return }
        let args: [String] = switch group {
        case .staged:
            ["restore", "--source=HEAD", "--staged", "--worktree", "--", file.path]
        case .unstaged:
            ["restore", "--", file.path]
        case .untracked:
            ["clean", "-f", "--", file.path]
        case .conflicts:
            ["restore", "--", file.path]
        }

        runMutating(in: repoPath, args: args) { [weak self] result in
            guard let self else { return }
            if result.success {
                ToastManager.shared.show("Discarded \(file.fileName)")
                refresh()
            } else {
                ToastManager.shared.show(cleanError(result.stderr), severity: .error)
            }
        }
    }

    // MARK: - Commit

    func toggleAmend() {
        isAmend.toggle()
        if isAmend, let last = lastCommitMessage {
            commitMessage = last
        } else if !isAmend {
            commitMessage = ""
        }
    }

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, let repoPath, !isBusy else { return }

        isCommitting = true

        var args = ["commit", "-m", message]
        if isAmend { args = ["commit", "--amend", "-m", message] }

        let wasAmend = isAmend
        runMutating(in: repoPath, args: args) { [weak self] result in
            guard let self else { return }
            isCommitting = false
            if result.success {
                commitMessage = ""
                isAmend = false
                ToastManager.shared.show(wasAmend ? "Amended commit." : "Committed changes.")
                recordActivity()
                refresh()
            } else {
                ToastManager.shared.show(cleanError(result.stderr), severity: .error)
            }
        }
    }

    // MARK: - Hunk Staging

    func stageHunk(_ hunk: GitDiffHunk, filePath: String, completion: (() -> Void)? = nil) {
        guard let repoPath, !isBusy else { return }
        isBusy = true
        let patch = hunk.toPatchString(filePath: filePath)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Git.shared.runWithStdin(
                in: repoPath,
                args: ["apply", "--cached", "--unidiff-zero", "-"],
                stdin: patch
            )
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                if result.success {
                    ToastManager.shared.show("Staged hunk")
                    self?.recordActivity()
                    self?.refresh()
                } else {
                    ToastManager.shared.show(self?.cleanError(result.stderr) ?? "Failed to stage hunk", severity: .error)
                }
                completion?()
            }
        }
    }

    func unstageHunk(_ hunk: GitDiffHunk, filePath: String, completion: (() -> Void)? = nil) {
        guard let repoPath, !isBusy else { return }
        isBusy = true
        let patch = hunk.toPatchString(filePath: filePath)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Git.shared.runWithStdin(
                in: repoPath,
                args: ["apply", "--cached", "--reverse", "--unidiff-zero", "-"],
                stdin: patch
            )
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                if result.success {
                    ToastManager.shared.show("Unstaged hunk")
                    self?.recordActivity()
                    self?.refresh()
                } else {
                    ToastManager.shared.show(self?.cleanError(result.stderr) ?? "Failed to unstage hunk", severity: .error)
                }
                completion?()
            }
        }
    }

    // MARK: - Review Export

    func copyReviewForAgent() {
        guard let project = ProjectStore.shared.activeProject,
              let selectedRoot = ProjectStore.shared.effectiveRootPath else { return }

        let markup = ReviewStore.shared.exportMarkup(
            repoRoot: project.path,
            selectedRoot: selectedRoot,
            baseRef: nil,
            headRef: currentBranch
        )

        guard !markup.isEmpty else {
            ToastManager.shared.show("Add at least one review comment before exporting.", severity: .warning)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markup, forType: .string)
        ToastManager.shared.show("Copied review for agent.")
    }

    func clearReviewComments() {
        guard let selectedRoot = ProjectStore.shared.effectiveRootPath else { return }
        ReviewStore.shared.clearComments(in: selectedRoot)
        ToastManager.shared.show("Cleared review comments.")
    }

    // MARK: - Helpers

    private func runMutating(in directory: String, args: [String], completion: @escaping (GitCommandResult) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Git.shared.runAsync(in: directory, args: args) { [weak self] result in
            DispatchQueue.main.async {
                self?.isBusy = false
                completion(result)
            }
        }
    }

    #if DEBUG
        func setDemo(statuses demoStatuses: [FileStatus]) {
            statuses = demoStatuses
            grouped = FileStatus.categorize(demoStatuses)
        }
    #endif

    private func cleanError(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Git command failed." : cleaned
    }

    private func recordActivity() {
        if let pid = ProjectStore.shared.activeProjectID {
            ProjectStore.shared.recordActivity(for: pid)
        }
        if let wsID = ProjectStore.shared.activeWorkspaceID {
            ProjectStore.shared.recordActivity(forWorkspace: wsID)
        }
    }
}
