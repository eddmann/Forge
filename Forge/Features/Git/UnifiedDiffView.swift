import SwiftUI

struct UnifiedDiffView: View {
    let diff: GitFileDiff
    @ObservedObject var viewModel: DiffViewModel
    @ObservedObject private var reviewStore = ReviewStore.shared
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    var body: some View {
        let fontSize = CGFloat(appearance.config.diffFontSize)
        let hasDraft = viewModel.draftComment != nil
        let draftAnchorID = viewModel.draftComment?.anchorLineID

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { hunkIdx, hunk in
                        hunkHeaderView(hunk: hunk, index: hunkIdx, fontSize: fontSize)

                        let wordDiffs = hunk.preparedWordDiffs()
                        ForEach(hunk.lines) { line in
                            if line.kind != .noNewlineMarker {
                                UnifiedLineRow(
                                    line: line,
                                    wordDiffSegments: wordDiffs[line.id],
                                    fontSize: fontSize,
                                    showCommentButton: !hasDraft,
                                    onComment: { beginComment(on: line) }
                                )

                                // Inline comments for this line
                                let lineNum = lineNumber(for: line)
                                let side = lineSide(for: line)
                                let comments = reviewStore.comments(
                                    in: viewModel.repoPath,
                                    filePath: viewModel.filePath,
                                    line: lineNum,
                                    side: side
                                )
                                ForEach(comments) { comment in
                                    InlineCommentCard(comment: comment, viewModel: viewModel)
                                }

                                // Inline draft editor anchored after this line
                                if draftAnchorID == line.id {
                                    InlineDraftEditor(viewModel: viewModel)
                                }
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

    // MARK: - Hunk Header

    private func hunkHeaderView(hunk: GitDiffHunk, index: Int, fontSize: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(hunk.header.isEmpty ? "@@" : hunk.header)
                .font(.system(size: fontSize - 2, design: .monospaced))
                .foregroundColor(.blue.opacity(0.8))
                .lineLimit(1)

            Spacer()

            if hunk.additions > 0 {
                Text("+\(hunk.additions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
            }
            if hunk.deletions > 0 {
                Text("-\(hunk.deletions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.red)
            }

            if !viewModel.staged {
                Button(action: { viewModel.stageHunk(hunk) }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
                .buttonStyle(.borderless)
                .help("Stage this hunk")
            } else {
                Button(action: { viewModel.unstageHunk(hunk) }) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                .help("Unstage this hunk")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.blue.opacity(0.05))
        .id("hunk-\(index)")
    }

    // MARK: - Helpers

    private func lineNumber(for line: GitDiffLine) -> Int {
        (line.kind == .removed ? line.oldLineNumber : line.newLineNumber) ?? 0
    }

    private func lineSide(for line: GitDiffLine) -> AgentReviewCommentSide {
        line.kind == .removed ? .old : .new
    }

    private func beginComment(on line: GitDiffLine) {
        let num = (line.kind == .removed ? line.oldLineNumber : line.newLineNumber) ?? 0
        let side: AgentReviewCommentSide = line.kind == .removed ? .old : .new
        viewModel.beginComment(
            startLine: num, endLine: num,
            side: side, codeSnippet: line.text,
            anchorLineID: line.id
        )
    }
}

// MARK: - Unified Line Row (no @ObservedObject — pure data + closures)

private struct UnifiedLineRow: View {
    let line: GitDiffLine
    let wordDiffSegments: [WordDiffSegment]?
    let fontSize: CGFloat
    let showCommentButton: Bool
    let onComment: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Comment button (appears on hover in the gutter)
            ZStack {
                if isHovered, showCommentButton {
                    Button(action: onComment) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.blue)
                            .cornerRadius(3)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(width: 20)

            // Old line number
            Text(line.oldLineNumber.map { String($0) } ?? "")
                .font(.system(size: fontSize - 2, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 36, alignment: .trailing)

            // New line number
            Text(line.newLineNumber.map { String($0) } ?? "")
                .font(.system(size: fontSize - 2, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 36, alignment: .trailing)

            // Prefix
            Text(line.prefix)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundColor(prefixColor)
                .frame(width: 16)

            // Content with pre-computed word-level diff
            if let segments = wordDiffSegments {
                WordDiffLineView(segments: segments, lineBackground: lineBackground, fontSize: fontSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            } else {
                Text(line.text)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(lineBackground)
        .onHover { isHovered = $0 }
        .onAppear { isHovered = false }
        .textSelection(.enabled)
    }

    private var lineBackground: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.08)
        case .removed: Color.red.opacity(0.08)
        default: .clear
        }
    }

    private var prefixColor: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: - Inline Comment Card

private struct InlineCommentCard: View {
    let comment: AgentReviewComment
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
        .padding(.leading, 92)
        .padding(.vertical, 4)
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

// MARK: - Inline Draft Editor

private struct InlineDraftEditor: View {
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
        .padding(.leading, 80)
        .padding(.vertical, 6)
    }
}
