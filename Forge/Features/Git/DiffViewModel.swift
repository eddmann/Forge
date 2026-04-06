import Combine
import Foundation
import SwiftUI

// MARK: - DiffViewMode

enum DiffViewMode: String, CaseIterable {
    case unified = "Unified"
    case split = "Split"

    var symbol: String {
        switch self {
        case .unified: "text.alignleft"
        case .split: "rectangle.split.2x1"
        }
    }
}

// MARK: - DraftCommentState

struct DraftCommentState {
    var filePath: String
    var startLine: Int
    var endLine: Int
    var side: AgentReviewCommentSide
    var codeSnippet: String
    var text: String = ""
    var category: AgentReviewCommentCategory = .suggestion
    var existingCommentID: String?

    /// The line ID after which to render the inline editor
    var anchorLineID: String?
}

// MARK: - DiffViewModel

@MainActor
final class DiffViewModel: ObservableObject {
    let filePath: String
    let repoPath: String
    let staged: Bool

    @Published var diff: GitFileDiff?
    @Published var isLoading = true
    @Published var error: String?
    @Published var viewMode: DiffViewMode = .init(rawValue: ForgeStore.shared.loadStateFields().diffViewMode) ?? .unified {
        didSet {
            ForgeStore.shared.updateStateFields { $0.diffViewMode = viewMode.rawValue }
        }
    }

    @Published var searchQuery = ""
    @Published var currentHunkIndex = 0
    @Published var draftComment: DraftCommentState?
    @Published var selectedLineIDs: Set<String> = []
    @Published var selectionAnchorID: String?
    @Published var contextExpanded = false

    private let diffService = GitDiffService.shared

    init(filePath: String, repoPath: String, staged: Bool) {
        self.filePath = filePath
        self.repoPath = repoPath
        self.staged = staged
    }

    // MARK: - Load Diff

    func loadDiff() {
        isLoading = true
        error = nil
        diff = nil

        // Handle untracked files
        if !staged, isUntrackedFile() {
            loadUntrackedDiff()
            return
        }

        let ctx = contextExpanded ? 99999 : 3
        let request: GitDiffRequest = staged
            ? .staged(paths: [filePath], contextLines: ctx)
            : .unstaged(paths: [filePath], contextLines: ctx)

        diffService.diffAsync(in: repoPath, request: request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case let .success(diffResult):
                    self.diff = diffResult.files.first(where: {
                        ($0.newPath ?? $0.oldPath) == self.filePath
                    }) ?? diffResult.files.first
                case let .failure(err):
                    self.error = err.localizedDescription
                }
            }
        }
    }

    func reload() {
        loadDiff()
    }

    func toggleContextExpansion() {
        contextExpanded.toggle()
        reload()
    }

    // MARK: - Hunk Navigation

    var totalHunks: Int {
        diff?.hunks.count ?? 0
    }

    func nextHunk() {
        guard totalHunks > 0 else { return }
        currentHunkIndex = min(currentHunkIndex + 1, totalHunks - 1)
    }

    func previousHunk() {
        guard totalHunks > 0 else { return }
        currentHunkIndex = max(currentHunkIndex - 1, 0)
    }

    // MARK: - Hunk Staging

    func stageHunk(_ hunk: GitDiffHunk) {
        StatusViewModel.shared.stageHunk(hunk, filePath: filePath) { [weak self] in
            self?.reload()
        }
    }

    func unstageHunk(_ hunk: GitDiffHunk) {
        StatusViewModel.shared.unstageHunk(hunk, filePath: filePath) { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Comments

    /// Begin a comment on selected lines, or a single line. Anchor determines where the inline editor appears.
    func beginComment(startLine: Int, endLine: Int, side: AgentReviewCommentSide, codeSnippet: String, anchorLineID: String?) {
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
        // Find the anchor line ID so the draft editor appears inline
        let anchorID = findAnchorLineID(line: comment.startLine, side: comment.side)
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

    private func findAnchorLineID(line: Int, side: AgentReviewCommentSide) -> String? {
        guard let allLines = diff?.hunks.flatMap(\.lines) else { return nil }
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

    // MARK: - Line Selection

    func toggleLineSelection(lineID: String) {
        if selectionAnchorID == nil {
            selectionAnchorID = lineID
            selectedLineIDs = [lineID]
        } else {
            // Extend selection from anchor to this line
            guard let allLines = diff?.hunks.flatMap(\.lines) else { return }
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

    /// Begin comment on currently selected lines.
    func commentOnSelection() {
        guard !selectedLineIDs.isEmpty,
              let allLines = diff?.hunks.flatMap(\.lines) else { return }

        let selected = allLines.filter { selectedLineIDs.contains($0.id) }
        guard let first = selected.first, let last = selected.last else { return }

        let startNum = (first.kind == .removed ? first.oldLineNumber : first.newLineNumber) ?? 0
        let endNum = (last.kind == .removed ? last.oldLineNumber : last.newLineNumber) ?? 0
        let side: AgentReviewCommentSide = first.kind == .removed ? .old : .new
        let snippet = selected.map(\.text).joined(separator: "\n")

        beginComment(
            startLine: startNum,
            endLine: endNum,
            side: side,
            codeSnippet: snippet,
            anchorLineID: last.id
        )
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

    // MARK: - Send to Agent

    func sendToAgent() {
        guard let project = ProjectStore.shared.activeProject else { return }
        let markup = ReviewStore.shared.exportMarkup(
            repoRoot: project.path,
            selectedRoot: repoPath,
            baseRef: nil,
            headRef: StatusViewModel.shared.currentBranch
        )
        guard !markup.isEmpty else { return }

        // Find the focused terminal and send
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

    private func isUntrackedFile() -> Bool {
        StatusViewModel.shared.statuses.first(where: { $0.path == filePath })?.isUntracked ?? false
    }

    private func loadUntrackedDiff() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let absolutePath = URL(fileURLWithPath: repoPath)
                .appendingPathComponent(filePath).path
            let data = (try? Data(contentsOf: URL(fileURLWithPath: absolutePath))) ?? Data()

            guard let content = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async {
                    self.diff = GitFileDiff(
                        oldPath: nil, newPath: self.filePath, change: .added,
                        isBinary: true, hunks: [], patch: "Binary file"
                    )
                    self.isLoading = false
                }
                return
            }

            let lines = content.components(separatedBy: .newlines)
            let visibleLines = lines.last == "" ? Array(lines.dropLast()) : lines
            let diffLines = visibleLines.enumerated().map { index, line in
                GitDiffLine(
                    id: "untracked-\(index + 1)",
                    kind: .added,
                    newLineNumber: index + 1,
                    text: line,
                    rawLine: "+" + line
                )
            }

            let hunk = GitDiffHunk(
                id: "untracked-0",
                oldStart: 0, oldCount: 0,
                newStart: visibleLines.isEmpty ? 0 : 1, newCount: visibleLines.count,
                header: "",
                rawHeader: "@@ -0,0 +1,\(visibleLines.count) @@",
                lines: diffLines
            )

            DispatchQueue.main.async {
                self.diff = GitFileDiff(
                    oldPath: nil, newPath: self.filePath, change: .added,
                    isBinary: false, hunks: [hunk],
                    patch: diffLines.map { "+\($0.text)" }.joined(separator: "\n")
                )
                self.isLoading = false
            }
        }
    }
}
