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
    @Published var feedbackMessage: String?
    @Published var feedbackIsError = false

    // MARK: - Private

    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private var repoPath: String? {
        ProjectStore.shared.effectiveRootPath ?? ProjectStore.shared.activeProject?.path
    }

    private init() {
        // Refresh when project/workspace changes (deferred to avoid publishing during view updates)
        ProjectStore.shared.$activeProjectID
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)

        ProjectStore.shared.$activeWorkspaceID
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
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
                setFeedback("Staged \(file.fileName)", isError: false)
                recordActivity()
                refresh()
            } else {
                setFeedback(cleanError(result.stderr), isError: true)
            }
        }
    }

    func unstage(file: FileStatus) {
        guard let repoPath else { return }
        runMutating(in: repoPath, args: ["restore", "--staged", "--", file.path]) { [weak self] result in
            guard let self else { return }
            if result.success {
                setFeedback("Unstaged \(file.fileName)", isError: false)
                recordActivity()
                refresh()
            } else {
                setFeedback(cleanError(result.stderr), isError: true)
            }
        }
    }

    func stageAll() {
        guard let repoPath else { return }
        runMutating(in: repoPath, args: ["add", "-A"]) { [weak self] result in
            guard let self else { return }
            if result.success {
                setFeedback("Staged all changes", isError: false)
                recordActivity()
                refresh()
            } else {
                setFeedback(cleanError(result.stderr), isError: true)
            }
        }
    }

    func unstageAll() {
        guard let repoPath else { return }
        runMutating(in: repoPath, args: ["reset", "HEAD"]) { [weak self] result in
            guard let self else { return }
            if result.success {
                setFeedback("Unstaged all changes", isError: false)
                recordActivity()
                refresh()
            } else {
                setFeedback(cleanError(result.stderr), isError: true)
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
                setFeedback("Discarded \(file.fileName)", isError: false)
                refresh()
            } else {
                setFeedback(cleanError(result.stderr), isError: true)
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
        feedbackMessage = nil

        var args = ["commit", "-m", message]
        if isAmend { args = ["commit", "--amend", "-m", message] }

        let wasAmend = isAmend
        runMutating(in: repoPath, args: args) { [weak self] result in
            guard let self else { return }
            isCommitting = false
            if result.success {
                commitMessage = ""
                isAmend = false
                setFeedback(wasAmend ? "Amended commit." : "Committed changes.", isError: false)
                recordActivity()
                refresh()
            } else {
                setFeedback(cleanError(result.stderr), isError: true)
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
                    self?.setFeedback("Staged hunk", isError: false)
                    self?.recordActivity()
                    self?.refresh()
                } else {
                    self?.setFeedback(self?.cleanError(result.stderr) ?? "Failed to stage hunk", isError: true)
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
                    self?.setFeedback("Unstaged hunk", isError: false)
                    self?.recordActivity()
                    self?.refresh()
                } else {
                    self?.setFeedback(self?.cleanError(result.stderr) ?? "Failed to unstage hunk", isError: true)
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
            setFeedback("Add at least one review comment before exporting.", isError: true)
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markup, forType: .string)
        setFeedback("Copied review for agent.", isError: false)
    }

    func clearReviewComments() {
        guard let selectedRoot = ProjectStore.shared.effectiveRootPath else { return }
        ReviewStore.shared.clearComments(in: selectedRoot)
        setFeedback("Cleared review comments.", isError: false)
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

    private var feedbackDismissTask: DispatchWorkItem?

    private func setFeedback(_ message: String, isError: Bool) {
        feedbackDismissTask?.cancel()
        feedbackMessage = message
        feedbackIsError = isError

        let task = DispatchWorkItem { [weak self] in
            self?.feedbackMessage = nil
        }
        feedbackDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: task)
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
    }
}
