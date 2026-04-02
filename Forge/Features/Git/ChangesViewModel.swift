import Combine
import Foundation
import SwiftUI

/// ViewModel for the shared Changes tab — loads ALL file diffs in one scroll.
/// When `branchDiffRequest` is set, loads a single revision-to-revision diff instead
/// of the working tree staged/unstaged flow (used for workspace diff view).
@MainActor
final class ChangesViewModel: ObservableObject {
    let repoPath: String
    let branchDiffRequest: GitDiffRequest?

    @Published var fileDiffs: [GitFileDiff] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var viewMode: DiffViewMode = .init(rawValue: ForgeStore.shared.loadStateFields().diffViewMode) ?? .unified {
        didSet {
            ForgeStore.shared.updateStateFields { $0.diffViewMode = viewMode.rawValue }
        }
    }

    @Published var scrollToFilePath: String?
    @Published var collapsedFiles: Set<String> = []

    // Per-file draft/selection state (keyed by file path)
    @Published var draftComment: DraftCommentState?
    @Published var selectedLineIDs: Set<String> = []
    @Published var selectionAnchorID: String?

    private let diffService = GitDiffService.shared
    private var scrollCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(repoPath: String, branchDiffRequest: GitDiffRequest? = nil) {
        self.repoPath = repoPath
        self.branchDiffRequest = branchDiffRequest
        loadAllDiffs()

        let scrollNotification: Notification.Name = branchDiffRequest != nil
            ? .scrollToFileInWorkspaceDiff
            : .scrollToFileInChanges
        listenForScrollRequests(notification: scrollNotification)

        // Only auto-reload from StatusViewModel for working tree diffs
        if branchDiffRequest == nil {
            StatusViewModel.shared.$statuses
                .dropFirst()
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.reload()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Load All Diffs

    func loadAllDiffs() {
        isLoading = true
        error = nil

        if let branchDiffRequest {
            loadBranchDiffs(request: branchDiffRequest)
            return
        }

        let statusVM = StatusViewModel.shared
        let statuses = statusVM.statuses

        // Load unstaged diffs (covers most changes)
        diffService.diffAsync(in: repoPath, request: .unstaged()) { [weak self] unstagedResult in
            guard let self else { return }

            // Also load staged diffs
            diffService.diffAsync(in: repoPath, request: .staged()) { [weak self] stagedResult in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isLoading = false

                    var allDiffs: [GitFileDiff] = []

                    // Add staged diffs
                    if case let .success(result) = stagedResult {
                        allDiffs += result.files
                    }

                    // Add unstaged diffs (skip duplicates already in staged)
                    if case let .success(result) = unstagedResult {
                        let stagedPaths = Set(allDiffs.compactMap { $0.newPath ?? $0.oldPath })
                        for file in result.files {
                            let path = file.newPath ?? file.oldPath ?? ""
                            if !stagedPaths.contains(path) {
                                allDiffs.append(file)
                            }
                        }
                    }

                    // Add untracked files as synthetic diffs
                    let diffPaths = Set(allDiffs.compactMap { $0.newPath ?? $0.oldPath })
                    for status in statuses where status.isUntracked && !diffPaths.contains(status.path) {
                        allDiffs.append(self.makeUntrackedDiff(for: status.path))
                    }

                    self.fileDiffs = allDiffs

                    if allDiffs.isEmpty, stagedResult == nil, unstagedResult == nil {
                        self.error = "Failed to load diffs"
                    }
                }
            }
        }
    }

    private func loadBranchDiffs(request: GitDiffRequest) {
        diffService.diffAsync(in: repoPath, request: request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case let .success(diffResult):
                    self.fileDiffs = diffResult.files
                case let .failure(err):
                    self.error = err.localizedDescription
                }
            }
        }
    }

    func reload() {
        loadAllDiffs()
    }

    // MARK: - Scroll To File

    private func listenForScrollRequests(notification: Notification.Name) {
        scrollCancellable = NotificationCenter.default.publisher(for: notification)
            .compactMap { $0.userInfo?["filePath"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] filePath in
                self?.scrollToFilePath = filePath
            }
    }

    // MARK: - Comments (delegates to DiffViewModel pattern)

    func beginComment(filePath: String, startLine: Int, endLine: Int, side: AgentReviewCommentSide, codeSnippet: String, anchorLineID: String?) {
        draftComment = DraftCommentState(
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            side: side,
            codeSnippet: codeSnippet,
            anchorLineID: anchorLineID
        )
        selectedLineIDs.removeAll()
        selectionAnchorID = nil
    }

    func editComment(_ comment: AgentReviewComment) {
        let anchorID = findAnchorLineID(filePath: comment.filePath, line: comment.startLine, side: comment.side)
        draftComment = DraftCommentState(
            filePath: comment.filePath,
            startLine: comment.startLine,
            endLine: comment.endLine,
            side: comment.side,
            codeSnippet: comment.codeSnippet,
            text: comment.text,
            category: comment.category,
            existingCommentID: comment.id,
            anchorLineID: anchorID
        )
    }

    private func findAnchorLineID(filePath: String, line: Int, side: AgentReviewCommentSide) -> String? {
        guard let fileDiff = fileDiffs.first(where: { ($0.newPath ?? $0.oldPath) == filePath }) else { return nil }
        let allLines = fileDiff.hunks.flatMap(\.lines)
        return allLines.first(where: { diffLine in
            let lineNum = side == .old ? diffLine.oldLineNumber : diffLine.newLineNumber
            return lineNum == line
        })?.id
    }

    func saveDraft() {
        guard let draft = draftComment else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let existingID = draft.existingCommentID {
            ReviewStore.shared.updateComment(
                rootPath: repoPath,
                filePath: draft.filePath,
                commentID: existingID,
                category: draft.category,
                text: text
            )
        } else {
            ReviewStore.shared.addComment(
                rootPath: repoPath,
                filePath: draft.filePath,
                startLine: draft.startLine,
                side: draft.side,
                category: draft.category,
                text: text,
                codeSnippet: draft.codeSnippet
            )
        }
        draftComment = nil
    }

    func cancelDraft() {
        draftComment = nil
    }

    func deleteComment(_ comment: AgentReviewComment) {
        ReviewStore.shared.removeComment(
            rootPath: repoPath,
            filePath: comment.filePath,
            commentID: comment.id
        )
    }

    // MARK: - Line Selection

    func toggleLineSelection(lineID: String, allLines: [GitDiffLine]) {
        if selectionAnchorID == nil {
            selectionAnchorID = lineID
            selectedLineIDs = [lineID]
        } else {
            let lineIDs = allLines.map(\.id)
            guard let anchorIdx = lineIDs.firstIndex(of: selectionAnchorID!),
                  let targetIdx = lineIDs.firstIndex(of: lineID) else { return }
            let range = min(anchorIdx, targetIdx) ... max(anchorIdx, targetIdx)
            selectedLineIDs = Set(lineIDs[range])
        }
    }

    func clearSelection() {
        selectedLineIDs.removeAll()
        selectionAnchorID = nil
    }

    func commentOnSelection(filePath: String, allLines: [GitDiffLine]) {
        guard !selectedLineIDs.isEmpty else { return }
        let selected = allLines.filter { selectedLineIDs.contains($0.id) }
        guard let first = selected.first, let last = selected.last else { return }

        let startNum = (first.kind == .removed ? first.oldLineNumber : first.newLineNumber) ?? 0
        let endNum = (last.kind == .removed ? last.oldLineNumber : last.newLineNumber) ?? 0
        let side: AgentReviewCommentSide = first.kind == .removed ? .old : .new
        let snippet = selected.map(\.text).joined(separator: "\n")

        beginComment(
            filePath: filePath,
            startLine: startNum, endLine: endNum,
            side: side, codeSnippet: snippet,
            anchorLineID: last.id
        )
    }

    // MARK: - Hunk Staging

    func stageHunk(_ hunk: GitDiffHunk, filePath: String) {
        StatusViewModel.shared.stageHunk(hunk, filePath: filePath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Review Export

    func sendToAgent() {
        guard let project = ProjectStore.shared.activeProject else { return }
        let markup = ReviewStore.shared.exportMarkup(
            repoRoot: project.path,
            selectedRoot: repoPath,
            baseRef: nil,
            headRef: StatusViewModel.shared.currentBranch
        )
        guard !markup.isEmpty else { return }
        guard let sessionID = TerminalSessionManager.shared.focusedSessionID,
              let terminalView = TerminalCache.shared.view(for: sessionID) else { return }
        terminalView.sendInput(markup)
    }

    func copyReview() {
        guard let project = ProjectStore.shared.activeProject else { return }
        let markup = ReviewStore.shared.exportMarkup(
            repoRoot: project.path,
            selectedRoot: repoPath,
            baseRef: nil,
            headRef: StatusViewModel.shared.currentBranch
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markup, forType: .string)
    }

    // MARK: - Private

    private func makeUntrackedDiff(for path: String) -> GitFileDiff {
        let absolutePath = URL(fileURLWithPath: repoPath).appendingPathComponent(path).path
        let data = (try? Data(contentsOf: URL(fileURLWithPath: absolutePath))) ?? Data()

        guard let content = String(data: data, encoding: .utf8) else {
            return GitFileDiff(oldPath: nil, newPath: path, change: .added, isBinary: true, hunks: [], patch: "Binary file")
        }

        let lines = content.components(separatedBy: .newlines)
        let visible = lines.last == "" ? Array(lines.dropLast()) : lines
        let diffLines = visible.enumerated().map { idx, line in
            GitDiffLine(id: "untracked-\(path)-\(idx)", kind: .added, newLineNumber: idx + 1, text: line, rawLine: "+" + line)
        }
        let hunk = GitDiffHunk(
            id: "untracked-\(path)", oldStart: 0, oldCount: 0,
            newStart: visible.isEmpty ? 0 : 1, newCount: visible.count,
            header: "", rawHeader: "@@ -0,0 +1,\(visible.count) @@", lines: diffLines
        )
        return GitFileDiff(oldPath: nil, newPath: path, change: .added, isBinary: false, hunks: [hunk], patch: "")
    }
}

/// Equatable conformance on Result for the nil check
private func == <T, E: Error>(_: Result<T, E>?, _: Result<T, E>?) -> Bool {
    false // Just used for nil checks
}
