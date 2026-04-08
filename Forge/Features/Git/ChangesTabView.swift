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

            // Expand / Collapse context
            Button(action: { viewModel.toggleContextExpansion() }) {
                HStack(spacing: 3) {
                    Image(systemName: viewModel.contextExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                    Text(viewModel.contextExpanded ? "Collapse" : "Expand")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.borderless)
            .help(viewModel.contextExpanded ? "Show only changed hunks" : "Show full file context")

            Divider().frame(height: 16)

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
            let fontSize = CGFloat(appearance.config.diffFontSize)
            let hasDraft = viewModel.draftComment != nil
            let fp = filePath

            let config = DiffTableConfig(
                repoPath: viewModel.repoPath,
                filePath: fp,
                staged: false,
                fontSize: fontSize,
                showCommentButtons: !hasDraft,
                draftAnchorLineID: viewModel.draftComment?.anchorLineID,
                currentHunkIndex: nil,
                onComment: { line, side in
                    let num = (side == .old ? line.oldLineNumber : line.newLineNumber) ?? 0
                    viewModel.beginComment(
                        filePath: fp,
                        startLine: num, endLine: num,
                        side: side, codeSnippet: line.text,
                        anchorLineID: line.id
                    )
                },
                onStageHunk: nil,
                onUnstageHunk: nil
            )

            let result = DiffRowBuilder.buildUnifiedRows(
                hunks: diff.hunks,
                multipleHunks: diff.hunks.count > 1,
                repoPath: viewModel.repoPath,
                filePath: fp,
                reviewStore: reviewStore,
                draftAnchorLineID: viewModel.draftComment?.anchorLineID
            )

            UnifiedDiffTableView(
                diff: diff,
                config: config,
                reviewStore: reviewStore,
                viewModel: viewModel,
                embeddedInScrollView: true
            )
            .frame(height: UnifiedDiffTableView<ChangesViewModel>.contentHeight(rows: result.rows, fontSize: fontSize))
        }
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
            let fontSize = CGFloat(appearance.config.diffFontSize)
            let hasDraft = viewModel.draftComment != nil
            let fp = filePath

            let config = DiffTableConfig(
                repoPath: viewModel.repoPath,
                filePath: fp,
                staged: false,
                fontSize: fontSize,
                showCommentButtons: !hasDraft,
                draftAnchorLineID: viewModel.draftComment?.anchorLineID,
                currentHunkIndex: nil,
                onComment: { line, side in
                    let num = (side == .old ? line.oldLineNumber : line.newLineNumber) ?? 0
                    viewModel.beginComment(
                        filePath: fp,
                        startLine: num, endLine: num,
                        side: side, codeSnippet: line.text,
                        anchorLineID: line.id
                    )
                },
                onStageHunk: nil,
                onUnstageHunk: nil
            )

            let result = DiffRowBuilder.buildSplitRows(
                hunks: diff.hunks,
                multipleHunks: diff.hunks.count > 1,
                repoPath: viewModel.repoPath,
                filePath: fp,
                reviewStore: reviewStore,
                draftAnchorLineID: viewModel.draftComment?.anchorLineID
            )

            SplitDiffTableView(
                diff: diff,
                config: config,
                reviewStore: reviewStore,
                viewModel: viewModel,
                embeddedInScrollView: true
            )
            .frame(height: SplitDiffTableView<ChangesViewModel>.contentHeight(rows: result.rows, fontSize: fontSize))
        }
    }
}
