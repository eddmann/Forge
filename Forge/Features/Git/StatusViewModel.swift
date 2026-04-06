import Combine
import Foundation
import SwiftUI

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

    private var refreshTimer: Timer?
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

        // Refresh when project/workspace changes (deferred to avoid publishing during view updates)
        ProjectStore.shared.$activeProjectID
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        ProjectStore.shared.$activeWorkspaceID
            .dropFirst()
            .sink { [weak self] newID in
                Task { @MainActor in
                    guard let self else { return }
                    // Save state under the previous workspace scope
                    self.saveToInspectorState(
                        projectID: self.previousProjectID,
                        workspaceID: self.previousWorkspaceID
                    )
                    // Update tracking
                    self.previousProjectID = ProjectStore.shared.activeProjectID
                    self.previousWorkspaceID = newID
                    // Restore from the new workspace scope
                    self.restoreFromInspectorState()
                    self.refresh()
                }
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
        stopAutoRefresh()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
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
        #if DEBUG
            if ProjectStore.shared.isDemo { return }
        #endif
        guard !isBusy else { return }
        guard let repoPath else {
            statuses = []
            grouped = [:]
            currentBranch = nil
            return
        }

        // Fetch status
        Git.shared.runAsync(in: repoPath, args: ["status", "--porcelain"]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if result.success {
                    self.statuses = FileStatus.parse(porcelain: result.stdout)
                    self.grouped = FileStatus.categorize(self.statuses)
                }
            }
        }

        // Fetch branch info
        Git.shared.runAsync(in: repoPath, args: ["rev-parse", "--abbrev-ref", "HEAD"]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if result.success {
                    let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.currentBranch = branch.isEmpty ? nil : branch
                    ProjectStore.shared.currentBranch = branch
                }
            }
        }

        // Fetch last commit message (for amend)
        Git.shared.runAsync(in: repoPath, args: ["log", "-1", "--format=%B"]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if result.success {
                    self.lastCommitMessage = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Fetch ahead/behind
        Git.shared.runAsync(in: repoPath, args: ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if result.success {
                    self.hasUpstream = true
                    let parts = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
                    self.ahead = parts.count > 0 ? Int(parts[0]) ?? 0 : 0
                    self.behind = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                } else {
                    self.hasUpstream = false
                    self.ahead = 0
                    self.behind = 0
                }
            }
        }
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
