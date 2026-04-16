import AppKit
import SwiftUI

/// NSViewRepresentable wrapping an NSTableView for split diff rendering.
/// Each row contains two half-cells (left/right) for the split view layout.
struct SplitDiffTableView<Host: DiffCommentHost>: NSViewRepresentable {
    let diff: GitFileDiff
    let config: DiffTableConfig
    let reviewStore: ReviewStore
    let viewModel: Host
    let embeddedInScrollView: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let tableView = DiffTableView()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.allowsEmptySelection = true
        tableView.contentLeadingInset = 0
        tableView.isSplitMode = true
        tableView.splitGutterInset = 58

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = !embeddedInScrollView
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        if embeddedInScrollView {
            scrollView.scrollsDynamically = false
        }

        context.coordinator.tableView = tableView
        context.coordinator.rebuild(diff: diff, config: config, reviewStore: reviewStore, viewModel: viewModel)

        return scrollView
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.rebuild(diff: diff, config: config, reviewStore: reviewStore, viewModel: viewModel)

        if let hunkIndex = config.currentHunkIndex {
            context.coordinator.scrollToHunk(index: hunkIndex)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: SplitDiffTableView
        weak var tableView: DiffTableView?
        var rows: [DiffRow] = []
        var hunkIndices: [Int] = []
        var currentConfig: DiffTableConfig?
        var currentViewModel: Host?
        private var lastScrolledHunkIndex: Int?
        private var lastRowIdentities: [String] = []
        private var lastFontSize: CGFloat = 0
        private var lastHighlights: FileHighlights = .empty

        init(parent: SplitDiffTableView) {
            self.parent = parent
        }

        func rebuild(diff: GitFileDiff, config: DiffTableConfig, reviewStore: ReviewStore, viewModel: Host) {
            currentConfig = config
            currentViewModel = viewModel

            let result = DiffRowBuilder.buildSplitRows(
                hunks: diff.hunks,
                multipleHunks: diff.hunks.count > 1,
                repoPath: config.repoPath,
                filePath: config.filePath,
                reviewStore: reviewStore,
                draftAnchorLineID: config.draftAnchorLineID
            )
            rows = result.rows
            hunkIndices = result.hunkIndices
            tableView?.diffRows = rows
            tableView?.fontSize = config.fontSize
            tableView?.recomputeMaxCodeWidth()

            let newIdentities = rows.map(\.identity)
            if newIdentities != lastRowIdentities || config.fontSize != lastFontSize || config.highlights != lastHighlights {
                tableView?.splitLeftOffset = 0
                tableView?.splitRightOffset = 0
                lastRowIdentities = newIdentities
                lastFontSize = config.fontSize
                lastHighlights = config.highlights
                tableView?.reloadData()
            }
        }

        func scrollToHunk(index: Int) {
            guard index != lastScrolledHunkIndex,
                  index < hunkIndices.count else { return }
            lastScrolledHunkIndex = index
            let rowIndex = hunkIndices[index]
            tableView?.scrollRowToVisible(rowIndex)
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in _: NSTableView) -> Int {
            rows.count
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }
            let config = currentConfig!

            switch rows[row] {
            case let .hunkHeader(hunk, index):
                let cell = tableView.makeView(
                    withIdentifier: HunkHeaderCellView.reuseIdentifier, owner: nil
                ) as? HunkHeaderCellView ?? HunkHeaderCellView()
                cell.identifier = HunkHeaderCellView.reuseIdentifier

                cell.configure(
                    hunk: hunk, index: index, fontSize: config.fontSize,
                    staged: config.staged,
                    onAction: { [weak self] in
                        guard let self, let cfg = currentConfig else { return }
                        if cfg.staged {
                            cfg.onUnstageHunk?(hunk)
                        } else {
                            cfg.onStageHunk?(hunk)
                        }
                    }
                )
                if config.onStageHunk == nil, config.onUnstageHunk == nil {
                    cell.hideActionButton()
                }
                return cell

            case let .splitLine(left, right, leftWordDiffs, rightWordDiffs):
                let cell = tableView.makeView(
                    withIdentifier: SplitLineCellView.reuseIdentifier, owner: nil
                ) as? SplitLineCellView ?? SplitLineCellView()
                cell.identifier = SplitLineCellView.reuseIdentifier

                let leftTokens = left.map { tokensFor(line: $0, highlights: config.highlights) } ?? []
                let rightTokens = right.map { tokensFor(line: $0, highlights: config.highlights) } ?? []
                cell.configure(
                    left: left, right: right,
                    leftWordDiffs: leftWordDiffs, rightWordDiffs: rightWordDiffs,
                    leftTokens: leftTokens, rightTokens: rightTokens,
                    fontSize: config.fontSize,
                    showCommentButton: config.showCommentButtons,
                    onComment: { [weak self] line, side in
                        self?.currentConfig?.onComment(line, side)
                    }
                )
                if let diffTV = tableView as? DiffTableView {
                    cell.applyHorizontalOffsets(left: diffTV.splitLeftOffset, right: diffTV.splitRightOffset)
                }
                return cell

            case let .inlineComment(comment):
                let cell = tableView.makeView(
                    withIdentifier: SwiftUIHostingCellView.commentReuseIdentifier, owner: nil
                ) as? SwiftUIHostingCellView ?? SwiftUIHostingCellView()
                cell.identifier = SwiftUIHostingCellView.commentReuseIdentifier

                if let vm = currentViewModel {
                    cell.configure(content: DiffInlineCommentCard(comment: comment, viewModel: vm))
                }
                return cell

            case .draftEditor:
                let cell = tableView.makeView(
                    withIdentifier: SwiftUIHostingCellView.draftReuseIdentifier, owner: nil
                ) as? SwiftUIHostingCellView ?? SwiftUIHostingCellView()
                cell.identifier = SwiftUIHostingCellView.draftReuseIdentifier

                if let vm = currentViewModel {
                    cell.configure(content: DiffInlineDraftEditor(viewModel: vm))
                }
                return cell

            case .unifiedLine:
                return nil
            }
        }

        func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return 20 }
            let fontSize = currentConfig?.fontSize ?? 13

            switch rows[row] {
            case .hunkHeader:
                return DiffCellMetrics.hunkHeaderHeight(fontSize: fontSize)
            case .splitLine, .unifiedLine:
                return DiffCellMetrics.lineRowHeight(fontSize: fontSize)
            case let .inlineComment(comment):
                let width = tableView?.bounds.width ?? 500
                return DiffCellMetrics.commentRowHeight(text: comment.text, fontSize: fontSize, availableWidth: width)
            case .draftEditor:
                return 180
            }
        }

        func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = DiffTableRowView()
            if let diffTV = tv as? DiffTableView {
                rowView.highlightRect = diffTV.highlightXRange(forRow: row)
            }
            return rowView
        }
    }
}

// MARK: - Content Height Calculation

extension SplitDiffTableView {
    static func contentHeight(rows: [DiffRow], fontSize: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        for row in rows {
            switch row {
            case .hunkHeader:
                height += DiffCellMetrics.hunkHeaderHeight(fontSize: fontSize)
            case .splitLine, .unifiedLine:
                height += DiffCellMetrics.lineRowHeight(fontSize: fontSize)
            case let .inlineComment(comment):
                height += DiffCellMetrics.commentRowHeight(text: comment.text, fontSize: fontSize, availableWidth: 500)
            case .draftEditor:
                height += 180
            }
        }
        return height
    }
}
