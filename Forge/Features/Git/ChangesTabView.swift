import SwiftUI

struct ChangesTabView: View {
    @ObservedObject var viewModel: ChangesViewModel
    @ObservedObject private var reviewStore = ReviewStore.shared
    @ObservedObject private var appearance = TerminalAppearanceStore.shared
    @State private var showSendToAgent = false

    var body: some View {
        VStack(spacing: 0) {
            changesToolbar
            Divider().opacity(0.3)

            if viewModel.isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading changes...")
                        .font(.system(size: 13))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.error {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Button("Retry") { viewModel.reload() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.fileDiffs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Text("No changes")
                        .font(.system(size: 13))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.fileDiffs) { fileDiff in
                                let filePath = fileDiff.newPath ?? fileDiff.oldPath ?? ""
                                let isCollapsed = viewModel.collapsedFiles.contains(filePath)

                                // File header (clickable to collapse)
                                fileHeader(fileDiff: fileDiff, isCollapsed: isCollapsed)
                                    .id("file-\(filePath)")

                                // File diff content (collapsible)
                                if !isCollapsed {
                                    switch viewModel.viewMode {
                                    case .unified:
                                        ChangesUnifiedFileView(
                                            diff: fileDiff,
                                            viewModel: viewModel
                                        )
                                    case .split:
                                        ChangesSplitFileView(
                                            diff: fileDiff,
                                            viewModel: viewModel
                                        )
                                    }
                                }

                                // Spacer between files
                                Spacer().frame(height: 20)
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .scrollToFileInChanges)) { notification in
                        guard let filePath = notification.userInfo?["filePath"] as? String else { return }
                        withAnimation {
                            proxy.scrollTo("file-\(filePath)", anchor: .top)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .scrollToFileInWorkspaceDiff)) { notification in
                        guard let filePath = notification.userInfo?["filePath"] as? String else { return }
                        withAnimation {
                            proxy.scrollTo("file-\(filePath)", anchor: .top)
                        }
                    }
                }
            }

            // Selection bar
            if !viewModel.selectedLineIDs.isEmpty {
                selectionBar
            }
        }
        .background(Color(nsColor: NSColor.windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var changesToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text(viewModel.branchDiffRequest != nil ? "Workspace Changes" : "Pending Changes")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)

            Text("\(viewModel.fileDiffs.count) files")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            let totalAdd = viewModel.fileDiffs.reduce(0) { $0 + $1.additions }
            let totalDel = viewModel.fileDiffs.reduce(0) { $0 + $1.deletions }
            Text("+\(totalAdd)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.green)
            Text("-\(totalDel)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.red)

            Spacer()

            // View mode toggle
            Picker("", selection: $viewModel.viewMode) {
                ForEach(DiffViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 80)

            Divider().frame(height: 16)

            Button(action: { showSendToAgent = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 11))
                    Text("Send to Agent")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.borderless)
            .disabled(reviewStore.allComments(in: viewModel.repoPath).isEmpty)
            .help("Send review to agent")
            .popover(isPresented: $showSendToAgent, arrowEdge: .bottom) {
                SendToAgentView(
                    markup: buildMarkup(),
                    repoPath: viewModel.repoPath,
                    onDismiss: { showSendToAgent = false }
                )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
    }

    // MARK: - File Header

    @ViewBuilder
    private func fileHeader(fileDiff: GitFileDiff, isCollapsed: Bool) -> some View {
        let filePath = fileDiff.newPath ?? fileDiff.oldPath ?? ""
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))

            Image(systemName: changeIcon(fileDiff.change))
                .font(.system(size: 11))
                .foregroundColor(changeColor(fileDiff.change))

            Text(filePath)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if fileDiff.isPureRename, let oldPath = fileDiff.oldPath {
                Text("← \(oldPath)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
            }

            Spacer()

            Text("+\(fileDiff.additions)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.green)
            Text("-\(fileDiff.deletions)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if viewModel.collapsedFiles.contains(filePath) {
                    viewModel.collapsedFiles.remove(filePath)
                } else {
                    viewModel.collapsedFiles.insert(filePath)
                }
            }
        }
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(viewModel.selectedLineIDs.count) lines selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button("Clear") { viewModel.clearSelection() }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
    }

    // MARK: - Helpers

    private func changeIcon(_ kind: GitFileChangeKind) -> String {
        switch kind {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        }
    }

    private func changeColor(_ kind: GitFileChangeKind) -> Color {
        switch kind {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        case .copied: .cyan
        }
    }

    private func buildMarkup() -> String {
        guard let project = ProjectStore.shared.activeProject else { return "" }
        return ReviewStore.shared.exportMarkup(
            repoRoot: project.path,
            selectedRoot: viewModel.repoPath,
            baseRef: nil,
            headRef: StatusViewModel.shared.currentBranch
        )
    }
}

// MARK: - Unified view for a single file within the all-files scroll

struct ChangesUnifiedFileView: View {
    let diff: GitFileDiff
    @ObservedObject var viewModel: ChangesViewModel
    @ObservedObject private var reviewStore = ReviewStore.shared
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    private var filePath: String {
        diff.newPath ?? diff.oldPath ?? ""
    }

    var body: some View {
        if diff.isBinary {
            HStack {
                Text("Binary file")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else if diff.hunks.isEmpty || diff.hunks.allSatisfy(\.lines.isEmpty) {
            let isDir = filePath.hasSuffix("/")
            HStack {
                Text(isDir ? "Directory" : "Empty file")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            LazyVStack(spacing: 0) {
                let multipleHunks = diff.hunks.count > 1
                ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                    // Only show hunk header when there are multiple hunks
                    if multipleHunks {
                        HStack(spacing: 8) {
                            Text(hunk.header.isEmpty ? "@@" : hunk.header)
                                .font(.system(size: CGFloat(appearance.config.diffFontSize) - 2, design: .monospaced))
                                .foregroundColor(.blue.opacity(0.8))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.blue.opacity(0.05))
                    }

                    // Lines
                    let linePairs = hunk.findLinePairs()
                    ForEach(hunk.lines) { line in
                        if line.kind != .noNewlineMarker {
                            ChangesLineRow(
                                line: line,
                                pairContent: linePairs[line.id],
                                filePath: filePath,
                                isSelected: viewModel.selectedLineIDs.contains(line.id),
                                viewModel: viewModel
                            )

                            // Inline comments
                            let lineNum = (line.kind == .removed ? line.oldLineNumber : line.newLineNumber) ?? 0
                            let side: AgentReviewCommentSide = line.kind == .removed ? .old : .new
                            let comments = reviewStore.comments(in: viewModel.repoPath, filePath: filePath, line: lineNum, side: side)
                            ForEach(comments) { comment in
                                InlineCommentCard(comment: comment, viewModel: viewModel)
                            }

                            // Inline draft
                            if viewModel.draftComment?.anchorLineID == line.id {
                                InlineDraftEditor(viewModel: viewModel)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Line row for Changes view

private struct ChangesLineRow: View {
    let line: GitDiffLine
    let pairContent: String?
    let filePath: String
    let isSelected: Bool
    @ObservedObject var viewModel: ChangesViewModel
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Comment button gutter
            ZStack {
                if isHovered, viewModel.draftComment == nil {
                    Button(action: { beginComment() }) {
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

            Text(line.oldLineNumber.map { String($0) } ?? "")
                .font(.system(size: CGFloat(appearance.config.diffFontSize) - 2, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 36, alignment: .trailing)

            Text(line.newLineNumber.map { String($0) } ?? "")
                .font(.system(size: CGFloat(appearance.config.diffFontSize) - 2, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 36, alignment: .trailing)

            Text(line.prefix)
                .font(.system(size: CGFloat(appearance.config.diffFontSize), design: .monospaced))
                .foregroundColor(prefixColor)
                .frame(width: 16)

            if let pairContent, line.kind == .added || line.kind == .removed {
                let segments = WordDiff.computeForLine(content: line.text, pairContent: pairContent, isAddition: line.kind == .added)
                WordDiffLineView(segments: segments, lineBackground: lineBackground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            } else {
                Text(line.text)
                    .font(.system(size: CGFloat(appearance.config.diffFontSize), design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .background(isSelected ? Color.blue.opacity(0.15) : lineBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            let allLines = viewModel.fileDiffs
                .first(where: { ($0.newPath ?? $0.oldPath) == filePath })?
                .hunks.flatMap(\.lines) ?? []
            if NSEvent.modifierFlags.contains(.shift) {
                viewModel.toggleLineSelection(lineID: line.id, allLines: allLines)
            } else {
                viewModel.clearSelection()
                viewModel.toggleLineSelection(lineID: line.id, allLines: allLines)
            }
        }
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

    private func beginComment() {
        let num = (line.kind == .removed ? line.oldLineNumber : line.newLineNumber) ?? 0
        let side: AgentReviewCommentSide = line.kind == .removed ? .old : .new
        viewModel.beginComment(
            filePath: filePath,
            startLine: num, endLine: num,
            side: side, codeSnippet: line.text,
            anchorLineID: line.id
        )
    }
}

// MARK: - Inline comment card (reused from UnifiedDiffView pattern)

private struct InlineCommentCard: View {
    let comment: AgentReviewComment
    @ObservedObject var viewModel: ChangesViewModel
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Category accent bar
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

// MARK: - Inline draft editor

private struct InlineDraftEditor: View {
    @ObservedObject var viewModel: ChangesViewModel
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

                Button("Cancel") {
                    viewModel.cancelDraft()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Comment") {
                    viewModel.saveDraft()
                }
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

// MARK: - Split view for a single file within the all-files scroll

struct ChangesSplitFileView: View {
    let diff: GitFileDiff
    @ObservedObject var viewModel: ChangesViewModel
    @ObservedObject private var reviewStore = ReviewStore.shared
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    private var filePath: String {
        diff.newPath ?? diff.oldPath ?? ""
    }

    var body: some View {
        if diff.isBinary {
            HStack {
                Text("Binary file").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else if diff.hunks.isEmpty || diff.hunks.allSatisfy(\.lines.isEmpty) {
            let isDir = filePath.hasSuffix("/")
            HStack {
                Text(isDir ? "Directory" : "Empty file").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else {
            GeometryReader { geo in
                let colWidth = (geo.size.width - 1) / 2
                let multipleHunks = diff.hunks.count > 1
                VStack(spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                        // Only show hunk header when there are multiple hunks
                        if multipleHunks {
                            HStack(spacing: 0) {
                                Text(hunk.header.isEmpty ? "@@" : hunk.header)
                                    .font(.system(size: CGFloat(appearance.config.diffFontSize) - 2, design: .monospaced))
                                    .foregroundColor(.blue.opacity(0.8))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                Spacer()
                            }
                            .frame(width: geo.size.width)
                            .background(Color.blue.opacity(0.05))
                        }

                        let rows = makeRows(from: hunk)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            // Split row with hover comment buttons
                            ChangesSplitLineRow(
                                left: row.0,
                                right: row.1,
                                columnWidth: colWidth,
                                totalWidth: geo.size.width,
                                filePath: filePath,
                                viewModel: viewModel
                            )

                            // Inline comments for this row
                            let anchorIDs = [row.0?.id, row.1?.id].compactMap { $0 }
                            ForEach(inlineComments(for: row), id: \.id) { comment in
                                InlineCommentCard(comment: comment, viewModel: viewModel)
                                    .frame(width: geo.size.width, alignment: .leading)
                            }

                            // Inline draft editor
                            if let anchorID = viewModel.draftComment?.anchorLineID,
                               anchorIDs.contains(anchorID)
                            {
                                InlineDraftEditor(viewModel: viewModel)
                                    .frame(width: geo.size.width, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: CGFloat(diff.hunks.flatMap(\.lines).count) * 22 + CGFloat(diff.hunks.count) * 24)
        }
    }

    private func inlineComments(for row: (GitDiffLine?, GitDiffLine?)) -> [AgentReviewComment] {
        var result: [AgentReviewComment] = []
        if let left = row.0, left.kind == .removed {
            let num = left.oldLineNumber ?? 0
            result += reviewStore.comments(in: viewModel.repoPath, filePath: filePath, line: num, side: .old)
        }
        if let right = row.1 {
            let num = right.newLineNumber ?? 0
            result += reviewStore.comments(in: viewModel.repoPath, filePath: filePath, line: num, side: .new)
        }
        return result
    }

    private func makeRows(from hunk: GitDiffHunk) -> [(GitDiffLine?, GitDiffLine?)] {
        var rows: [(GitDiffLine?, GitDiffLine?)] = []
        var i = 0; let lines = hunk.lines
        while i < lines.count {
            switch lines[i].kind {
            case .context:
                rows.append((lines[i], lines[i])); i += 1
            case .removed:
                var dels: [GitDiffLine] = []; var j = i
                while j < lines.count, lines[j].kind == .removed {
                    dels.append(lines[j]); j += 1
                }
                var adds: [GitDiffLine] = []
                while j < lines.count, lines[j].kind == .added {
                    adds.append(lines[j]); j += 1
                }
                for k in 0 ..< max(dels.count, adds.count) {
                    rows.append((k < dels.count ? dels[k] : nil, k < adds.count ? adds[k] : nil))
                }
                i = j
            case .added:
                rows.append((nil, lines[i])); i += 1
            case .noNewlineMarker:
                i += 1
            }
        }
        return rows
    }
}

// MARK: - Split line row with hover comment buttons (Changes tab)

private struct ChangesSplitLineRow: View {
    let left: GitDiffLine?
    let right: GitDiffLine?
    let columnWidth: CGFloat
    let totalWidth: CGFloat
    let filePath: String
    @ObservedObject var viewModel: ChangesViewModel
    @ObservedObject private var appearance = TerminalAppearanceStore.shared

    @State private var leftHovered = false
    @State private var rightHovered = false

    var body: some View {
        HStack(spacing: 0) {
            splitCell(line: left, side: .old, width: columnWidth, isHovered: $leftHovered)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            splitCell(line: right, side: .new, width: columnWidth, isHovered: $rightHovered)
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
                Text((side == .old ? line.oldLineNumber : line.newLineNumber).map { String($0) } ?? "")
                    .font(.system(size: CGFloat(appearance.config.diffFontSize) - 2, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 32, alignment: .trailing)
                    .padding(.trailing, 4)

                // Content
                Text(line.text)
                    .font(.system(size: CGFloat(appearance.config.diffFontSize), design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.vertical, 1)
            .background(bgColor(for: line.kind))
            .frame(width: width).clipped()
            .contentShape(Rectangle())
            .onHover { isHovered.wrappedValue = $0 }
        } else {
            Color(nsColor: NSColor.separatorColor).frame(width: width, height: 20)
        }
    }

    private func bgColor(for kind: GitDiffLineKind) -> Color {
        switch kind {
        case .added: Color.green.opacity(0.1)
        case .removed: Color.red.opacity(0.1)
        default: .clear
        }
    }

    private func beginComment(line: GitDiffLine, side: AgentReviewCommentSide) {
        let num = (side == .old ? line.oldLineNumber : line.newLineNumber) ?? 0
        viewModel.beginComment(
            filePath: filePath,
            startLine: num, endLine: num,
            side: side, codeSnippet: line.text,
            anchorLineID: line.id
        )
    }
}
