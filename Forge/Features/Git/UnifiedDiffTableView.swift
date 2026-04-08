import AppKit
import SwiftUI

/// NSViewRepresentable wrapping an NSTableView for unified diff rendering.
/// Replaces the SwiftUI LazyVStack + ForEach line rendering with native cell recycling.
struct UnifiedDiffTableView<Host: DiffCommentHost>: NSViewRepresentable {
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
        // Gutter width: 20 (comment btn) + 36 (old#) + 36 (new#) + 16 (prefix) = 108
        tableView.contentLeadingInset = 108

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
        var parent: UnifiedDiffTableView
        weak var tableView: DiffTableView?
        var rows: [DiffRow] = []
        var hunkIndices: [Int] = []
        var currentConfig: DiffTableConfig?
        var currentViewModel: Host?
        private var lastScrolledHunkIndex: Int?
        private var lastRowIdentities: [String] = []
        private var lastFontSize: CGFloat = 0

        init(parent: UnifiedDiffTableView) {
            self.parent = parent
        }

        func rebuild(diff: GitFileDiff, config: DiffTableConfig, reviewStore: ReviewStore, viewModel: Host) {
            currentConfig = config
            currentViewModel = viewModel

            let result = DiffRowBuilder.buildUnifiedRows(
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

            let newIdentities = rows.map(\.identity)
            if newIdentities != lastRowIdentities || config.fontSize != lastFontSize {
                lastRowIdentities = newIdentities
                lastFontSize = config.fontSize
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

            case let .unifiedLine(line, wordDiffs):
                let cell = tableView.makeView(
                    withIdentifier: UnifiedLineCellView.reuseIdentifier, owner: nil
                ) as? UnifiedLineCellView ?? UnifiedLineCellView()
                cell.identifier = UnifiedLineCellView.reuseIdentifier

                cell.configure(
                    line: line, wordDiffs: wordDiffs,
                    fontSize: config.fontSize,
                    showCommentButton: config.showCommentButtons,
                    onComment: { [weak self] in
                        guard let self, let cfg = currentConfig else { return }
                        let side: AgentReviewCommentSide = line.kind == .removed ? .old : .new
                        cfg.onComment(line, side)
                    }
                )
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

            case .splitLine:
                return nil
            }
        }

        func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rows.count else { return 20 }
            let fontSize = currentConfig?.fontSize ?? 13

            switch rows[row] {
            case .hunkHeader:
                return DiffCellMetrics.hunkHeaderHeight(fontSize: fontSize)
            case .unifiedLine, .splitLine:
                return DiffCellMetrics.lineRowHeight(fontSize: fontSize)
            case .inlineComment:
                return 80
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

extension UnifiedDiffTableView {
    /// Computes the total content height for embedded mode (no own scroll).
    static func contentHeight(rows: [DiffRow], fontSize: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        for row in rows {
            switch row {
            case .hunkHeader:
                height += DiffCellMetrics.hunkHeaderHeight(fontSize: fontSize)
            case .unifiedLine, .splitLine:
                height += DiffCellMetrics.lineRowHeight(fontSize: fontSize)
            case .inlineComment:
                height += 80
            case .draftEditor:
                height += 180
            }
        }
        return height
    }
}
