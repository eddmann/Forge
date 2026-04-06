import SwiftUI

struct SplitDiffView: View {
    let diff: GitFileDiff
    @ObservedObject var viewModel: DiffViewModel
    @ObservedObject private var reviewStore = ReviewStore.shared
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    var body: some View {
        GeometryReader { geo in
            let columnWidth = (geo.size.width - 1) / 2

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { hunkIdx, hunk in
                            // Hunk header
                            HStack(spacing: 0) {
                                Text(hunk.header.isEmpty ? "@@" : hunk.header)
                                    .font(.system(size: CGFloat(appearance.config.diffFontSize) - 2, design: .monospaced))
                                    .foregroundColor(.blue.opacity(0.8))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                Spacer()
                            }
                            .frame(width: geo.size.width)
                            .background(Color.blue.opacity(0.05))
                            .id("hunk-\(hunkIdx)")

                            // Paired lines
                            let rows = makeRows(from: hunk)
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                // The split row
                                SplitLineRow(
                                    row: row,
                                    columnWidth: columnWidth,
                                    totalWidth: geo.size.width,
                                    viewModel: viewModel,
                                    reviewStore: reviewStore
                                )

                                // Inline comments after this row (anchored to either side's line)
                                let anchorIDs = [row.left?.id, row.right?.id].compactMap { $0 }
                                ForEach(inlineComments(for: row), id: \.id) { comment in
                                    SplitInlineCommentCard(
                                        comment: comment,
                                        totalWidth: geo.size.width,
                                        viewModel: viewModel
                                    )
                                }

                                // Draft editor anchored here
                                if let anchorID = viewModel.draftComment?.anchorLineID,
                                   anchorIDs.contains(anchorID)
                                {
                                    SplitInlineDraftEditor(
                                        totalWidth: geo.size.width,
                                        viewModel: viewModel
                                    )
                                }
                            }
                        }
                    }
                }
                .onChange(of: viewModel.currentHunkIndex) { _, newIndex in
                    withAnimation { proxy.scrollTo("hunk-\(newIndex)", anchor: .top) }
                }
            }
        }
    }

    // MARK: - Row Pairing

    struct SplitRow {
        var left: GitDiffLine?
        var right: GitDiffLine?
    }

    private func makeRows(from hunk: GitDiffHunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var i = 0
        let lines = hunk.lines

        while i < lines.count {
            let line = lines[i]
            switch line.kind {
            case .context:
                rows.append(SplitRow(left: line, right: line))
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
                    rows.append(SplitRow(
                        left: k < removals.count ? removals[k] : nil,
                        right: k < additions.count ? additions[k] : nil
                    ))
                }
                i = j
            case .added:
                rows.append(SplitRow(left: nil, right: line))
                i += 1
            case .noNewlineMarker:
                i += 1
            }
        }
        return rows
    }

    // MARK: - Inline comments for a row

    private func inlineComments(for row: SplitRow) -> [AgentReviewComment] {
        var result: [AgentReviewComment] = []
        // Left side: check old line number for removed or context lines
        if let left = row.left, let num = left.oldLineNumber, left.kind == .removed || left.kind == .context {
            result += reviewStore.comments(in: viewModel.repoPath, filePath: viewModel.filePath, line: num, side: .old)
        }
        // Right side: check new line number for added or context lines
        if let right = row.right, let num = right.newLineNumber, right.kind == .added || right.kind == .context {
            result += reviewStore.comments(in: viewModel.repoPath, filePath: viewModel.filePath, line: num, side: .new)
        }
        return result
    }
}

// MARK: - Split Line Row

private struct SplitLineRow: View {
    let row: SplitDiffView.SplitRow
    let columnWidth: CGFloat
    let totalWidth: CGFloat
    @ObservedObject var viewModel: DiffViewModel
    @ObservedObject var reviewStore: ReviewStore
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    @State private var leftHovered = false
    @State private var rightHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Left column
            splitCell(
                line: row.left,
                side: .old,
                width: columnWidth,
                isHovered: $leftHovered
            )

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            // Right column
            splitCell(
                line: row.right,
                side: .new,
                width: columnWidth,
                isHovered: $rightHovered
            )
        }
        .frame(width: totalWidth)
    }

    @ViewBuilder
    private func splitCell(line: GitDiffLine?, side: AgentReviewCommentSide, width: CGFloat, isHovered: Binding<Bool>) -> some View {
        if let line {
            HStack(spacing: 0) {
                // Hover comment button
                ZStack {
                    if isHovered.wrappedValue, viewModel.draftComment == nil {
                        Button(action: { beginComment(line: line, side: side) }) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 14, height: 14)
                                .background(Color.blue)
                                .cornerRadius(3)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(width: 18)

                // Line number
                Text(lineNumber(for: line, side: side))
                    .font(.system(size: CGFloat(appearance.config.diffFontSize) - 2, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 32, alignment: .trailing)
                    .padding(.trailing, 4)

                // Content
                Text(line.text)
                    .font(.system(size: CGFloat(appearance.config.diffFontSize), design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.vertical, 1)
            .background(backgroundColor(for: line.kind))
            .frame(width: width)
            .clipped()
            .onHover { isHovered.wrappedValue = $0 }
            .textSelection(.enabled)
        } else {
            Color(nsColor: NSColor.separatorColor)
                .frame(width: width, height: 20)
        }
    }

    private func lineNumber(for line: GitDiffLine, side: AgentReviewCommentSide) -> String {
        let num = side == .old ? line.oldLineNumber : line.newLineNumber
        return num.map { String($0) } ?? ""
    }

    private func backgroundColor(for kind: GitDiffLineKind) -> Color {
        switch kind {
        case .added: Color.green.opacity(0.1)
        case .removed: Color.red.opacity(0.1)
        default: .clear
        }
    }

    private func beginComment(line: GitDiffLine, side: AgentReviewCommentSide) {
        let num = (side == .old ? line.oldLineNumber : line.newLineNumber) ?? 0
        viewModel.beginComment(
            startLine: num, endLine: num,
            side: side, codeSnippet: line.text,
            anchorLineID: line.id
        )
    }
}

// MARK: - Split Inline Comment Card

private struct SplitInlineCommentCard: View {
    let comment: AgentReviewComment
    let totalWidth: CGFloat
    @ObservedObject var viewModel: DiffViewModel
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(categoryColor)
                .frame(width: 3)
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: categoryIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(categoryColor)
                    Text(comment.category.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(categoryColor)
                    Spacer()
                    Button(action: { viewModel.editComment(comment) }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .opacity(0.7)
                    Button(action: { viewModel.deleteComment(comment) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .opacity(0.7)
                }

                Text(comment.text)
                    .font(.system(size: CGFloat(appearance.config.diffFontSize)))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, 10)
            .padding(.vertical, 8)
            .padding(.trailing, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: NSColor.quaternaryLabelColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(categoryColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(width: totalWidth, alignment: .leading)
    }

    private var categoryColor: Color {
        switch comment.category {
        case .issue: .red
        case .suggestion: .blue
        case .question: .purple
        case .nitpick: Color(nsColor: .tertiaryLabelColor)
        case .praise: .green
        }
    }

    private var categoryIcon: String {
        switch comment.category {
        case .issue: "exclamationmark.circle"
        case .suggestion: "lightbulb"
        case .question: "questionmark.circle"
        case .nitpick: "text.magnifyingglass"
        case .praise: "hand.thumbsup"
        }
    }
}

// MARK: - Split Inline Draft Editor

private struct SplitInlineDraftEditor: View {
    let totalWidth: CGFloat
    @ObservedObject var viewModel: DiffViewModel
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Leave a comment")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)

            TextEditor(text: Binding(
                get: { viewModel.draftComment?.text ?? "" },
                set: { viewModel.draftComment?.text = $0 }
            ))
            .font(.system(size: CGFloat(appearance.config.diffFontSize)))
            .frame(minHeight: 60, maxHeight: 140)
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: NSColor.windowBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
            )

            HStack(spacing: 10) {
                Picker("", selection: Binding(
                    get: { viewModel.draftComment?.category ?? .suggestion },
                    set: { viewModel.draftComment?.category = $0 }
                )) {
                    ForEach(AgentReviewCommentCategory.allCases, id: \.self) { cat in
                        Text(cat.rawValue.capitalized).tag(cat)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)

                Spacer()

                Button("Cancel") { viewModel.cancelDraft() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Comment") { viewModel.saveDraft() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled((viewModel.draftComment?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor.quaternaryLabelColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(width: totalWidth, alignment: .leading)
    }
}
