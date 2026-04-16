import AppKit
import SwiftUI

// MARK: - DiffRow

/// Flat row model for NSTableView rendering of diff content.
/// All row types (hunk headers, diff lines, inline comments, draft editors)
/// are unified into a single array consumed by the table data source.
enum DiffRow {
    case hunkHeader(hunk: GitDiffHunk, index: Int)
    case unifiedLine(line: GitDiffLine, wordDiffs: [WordDiffSegment]?)
    case splitLine(left: GitDiffLine?, right: GitDiffLine?, leftWordDiffs: [WordDiffSegment]?, rightWordDiffs: [WordDiffSegment]?)
    case inlineComment(comment: AgentReviewComment)
    case draftEditor(anchorLineID: String)

    /// Lightweight structural identity for change detection (avoids unnecessary reloadData).
    var identity: String {
        switch self {
        case let .hunkHeader(_, index): "h\(index)"
        case let .unifiedLine(line, _): "u\(line.id)"
        case let .splitLine(left, right, _, _): "s\(left?.id ?? "")\(right?.id ?? "")"
        case let .inlineComment(comment): "c\(comment.id)"
        case let .draftEditor(id): "d\(id)"
        }
    }

    /// Text content for copy operations. Returns nil for non-text rows.
    var copyableText: String? {
        switch self {
        case let .unifiedLine(line, _):
            line.text
        case let .splitLine(left, right, _, _):
            right?.text ?? left?.text
        case let .hunkHeader(hunk, _):
            hunk.header
        case .inlineComment, .draftEditor:
            nil
        }
    }

    /// Side-aware text extraction for split view copy.
    func copyableText(side: SplitSelectionSide) -> String? {
        switch self {
        case let .unifiedLine(line, _):
            line.text
        case let .splitLine(left, right, _, _):
            switch side {
            case .left: left?.text
            case .right: right?.text
            }
        case let .hunkHeader(hunk, _):
            hunk.header
        case .inlineComment, .draftEditor:
            nil
        }
    }
}

// MARK: - Highlight lookup

/// Looks up syntax highlight tokens for a diff line. Pure context lines map onto whichever
/// side has a line number (preferring new). Removed lines use the old-side mapping; added
/// lines use the new-side mapping.
func tokensFor(line: GitDiffLine, highlights: FileHighlights) -> [HighlightToken] {
    switch line.kind {
    case .added:
        guard let n = line.newLineNumber else { return [] }
        return highlights.newSide[n]?.tokens ?? []
    case .removed:
        guard let n = line.oldLineNumber else { return [] }
        return highlights.oldSide[n]?.tokens ?? []
    case .context:
        if let n = line.newLineNumber, let lh = highlights.newSide[n] { return lh.tokens }
        if let n = line.oldLineNumber, let lh = highlights.oldSide[n] { return lh.tokens }
        return []
    case .noNewlineMarker:
        return []
    }
}

// MARK: - DiffTableConfig

/// ViewModel-agnostic configuration passed to NSTableView representables.
struct DiffTableConfig {
    let repoPath: String
    let filePath: String
    let staged: Bool
    let fontSize: CGFloat
    let showCommentButtons: Bool
    let draftAnchorLineID: String?
    let currentHunkIndex: Int?
    let highlights: FileHighlights
    let onComment: (GitDiffLine, AgentReviewCommentSide) -> Void
    let onStageHunk: ((GitDiffHunk) -> Void)?
    let onUnstageHunk: ((GitDiffHunk) -> Void)?
}

// MARK: - DiffRowBuilder

enum DiffRowBuilder {
    /// Flattens hunks into a unified-mode row array, interleaving inline comments and draft editors.
    static func buildUnifiedRows(
        hunks: [GitDiffHunk],
        multipleHunks: Bool,
        repoPath: String,
        filePath: String,
        reviewStore: ReviewStore,
        draftAnchorLineID: String?
    ) -> (rows: [DiffRow], hunkIndices: [Int]) {
        var rows: [DiffRow] = []
        var hunkIndices: [Int] = []

        for (hunkIdx, hunk) in hunks.enumerated() {
            if multipleHunks {
                hunkIndices.append(rows.count)
                rows.append(.hunkHeader(hunk: hunk, index: hunkIdx))
            }

            let wordDiffs = hunk.preparedWordDiffs()

            for line in hunk.lines {
                guard line.kind != .noNewlineMarker else { continue }

                rows.append(.unifiedLine(line: line, wordDiffs: wordDiffs[line.id]))

                // Inline comments after this line
                let lineNum = (line.kind == .removed ? line.oldLineNumber : line.newLineNumber) ?? 0
                let side: AgentReviewCommentSide = line.kind == .removed ? .old : .new
                let comments = reviewStore.comments(in: repoPath, filePath: filePath, line: lineNum, side: side)
                for comment in comments {
                    rows.append(.inlineComment(comment: comment))
                }

                // Draft editor anchored after this line
                if draftAnchorLineID == line.id {
                    rows.append(.draftEditor(anchorLineID: line.id))
                }
            }
        }

        return (rows, hunkIndices)
    }

    /// Flattens hunks into a split-mode row array with paired left/right lines.
    static func buildSplitRows(
        hunks: [GitDiffHunk],
        multipleHunks: Bool,
        repoPath: String,
        filePath: String,
        reviewStore: ReviewStore,
        draftAnchorLineID: String?
    ) -> (rows: [DiffRow], hunkIndices: [Int]) {
        var rows: [DiffRow] = []
        var hunkIndices: [Int] = []

        for (hunkIdx, hunk) in hunks.enumerated() {
            if multipleHunks {
                hunkIndices.append(rows.count)
                rows.append(.hunkHeader(hunk: hunk, index: hunkIdx))
            }

            let wordDiffs = hunk.preparedWordDiffs()
            let pairedRows = makeSplitPairs(from: hunk)

            for (left, right) in pairedRows {
                let leftWordDiffs = left.flatMap { wordDiffs[$0.id] }
                let rightWordDiffs = right.flatMap { wordDiffs[$0.id] }
                rows.append(.splitLine(left: left, right: right, leftWordDiffs: leftWordDiffs, rightWordDiffs: rightWordDiffs))

                // Inline comments for this row
                let anchorIDs = [left?.id, right?.id].compactMap { $0 }
                appendSplitInlineComments(
                    to: &rows, left: left, right: right,
                    repoPath: repoPath, filePath: filePath, reviewStore: reviewStore
                )

                // Draft editor
                if let anchorID = draftAnchorLineID, anchorIDs.contains(anchorID) {
                    rows.append(.draftEditor(anchorLineID: anchorID))
                }
            }
        }

        return (rows, hunkIndices)
    }

    // MARK: - Private

    /// Pairs deletion/addition lines for split view, same algorithm as the original makeRows.
    private static func makeSplitPairs(from hunk: GitDiffHunk) -> [(GitDiffLine?, GitDiffLine?)] {
        var pairs: [(GitDiffLine?, GitDiffLine?)] = []
        var i = 0
        let lines = hunk.lines

        while i < lines.count {
            switch lines[i].kind {
            case .context:
                pairs.append((lines[i], lines[i]))
                i += 1
            case .removed:
                var removals: [GitDiffLine] = []
                var j = i
                while j < lines.count, lines[j].kind == .removed {
                    removals.append(lines[j]); j += 1
                }
                var additions: [GitDiffLine] = []
                while j < lines.count, lines[j].kind == .added {
                    additions.append(lines[j]); j += 1
                }
                let maxCount = max(removals.count, additions.count)
                for k in 0 ..< maxCount {
                    pairs.append((
                        k < removals.count ? removals[k] : nil,
                        k < additions.count ? additions[k] : nil
                    ))
                }
                i = j
            case .added:
                pairs.append((nil, lines[i]))
                i += 1
            case .noNewlineMarker:
                i += 1
            }
        }
        return pairs
    }

    private static func appendSplitInlineComments(
        to rows: inout [DiffRow],
        left: GitDiffLine?,
        right: GitDiffLine?,
        repoPath: String,
        filePath: String,
        reviewStore: ReviewStore
    ) {
        if let left, let num = left.oldLineNumber, left.kind == .removed || left.kind == .context {
            for comment in reviewStore.comments(in: repoPath, filePath: filePath, line: num, side: .old) {
                rows.append(.inlineComment(comment: comment))
            }
        }
        if let right, let num = right.newLineNumber, right.kind == .added || right.kind == .context {
            for comment in reviewStore.comments(in: repoPath, filePath: filePath, line: num, side: .new) {
                rows.append(.inlineComment(comment: comment))
            }
        }
    }
}
