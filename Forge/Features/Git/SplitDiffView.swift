import SwiftUI

struct SplitDiffView: View {
    let diff: GitFileDiff
    @ObservedObject var viewModel: DiffViewModel
    @ObservedObject private var reviewStore = ReviewStore.shared
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    var body: some View {
        let fontSize = CGFloat(appearance.config.diffFontSize)
        let hasDraft = viewModel.draftComment != nil

        SplitDiffTableView(
            diff: diff,
            config: DiffTableConfig(
                repoPath: viewModel.repoPath,
                filePath: viewModel.filePath,
                staged: viewModel.staged,
                fontSize: fontSize,
                showCommentButtons: !hasDraft,
                draftAnchorLineID: viewModel.draftComment?.anchorLineID,
                currentHunkIndex: viewModel.currentHunkIndex,
                onComment: { line, side in
                    let num = (side == .old ? line.oldLineNumber : line.newLineNumber) ?? 0
                    viewModel.beginComment(
                        startLine: num, endLine: num,
                        side: side, codeSnippet: line.text,
                        anchorLineID: line.id
                    )
                },
                onStageHunk: viewModel.staged ? nil : { hunk in viewModel.stageHunk(hunk) },
                onUnstageHunk: viewModel.staged ? { hunk in viewModel.unstageHunk(hunk) } : nil
            ),
            reviewStore: reviewStore,
            viewModel: viewModel,
            embeddedInScrollView: false
        )
    }
}
