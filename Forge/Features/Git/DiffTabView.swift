import SwiftUI

struct DiffTabView: View {
    @ObservedObject var viewModel: DiffViewModel
    @ObservedObject private var reviewStore = ReviewStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            diffToolbar

            Divider().opacity(0.3)

            // Content
            if viewModel.isLoading {
                VStack {
                    Spacer()
                    ProgressView("Loading diff...")
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
                        .multilineTextAlignment(.center)
                    Button("Retry") { viewModel.reload() }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diff = viewModel.diff {
                if diff.isBinary {
                    binaryFileView(diff)
                } else if diff.hunks.isEmpty {
                    emptyDiffView
                } else {
                    // Diff content
                    switch viewModel.viewMode {
                    case .unified:
                        UnifiedDiffView(diff: diff, viewModel: viewModel)
                    case .split:
                        SplitDiffView(diff: diff, viewModel: viewModel)
                    }
                }
            } else {
                emptyDiffView
            }

            // Selection action bar
            if !viewModel.selectedLineIDs.isEmpty {
                selectionBar
            }
        }
        .background(Color(nsColor: NSColor.windowBackgroundColor))
        .onAppear { viewModel.loadDiff() }
    }

    // MARK: - Toolbar

    private var diffToolbar: some View {
        HStack(spacing: 8) {
            // File path
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text(viewModel.filePath)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if viewModel.staged {
                Text("STAGED")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(3)
            }

            Spacer()

            // Stats
            if let diff = viewModel.diff {
                HStack(spacing: 4) {
                    Text("+\(diff.additions)")
                        .foregroundColor(.green)
                    Text("-\(diff.deletions)")
                        .foregroundColor(.red)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }

            // Hunk navigation
            if viewModel.totalHunks > 0 {
                Divider().frame(height: 16)

                HStack(spacing: 4) {
                    Button(action: { viewModel.previousHunk() }) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.currentHunkIndex == 0)

                    Text("\(viewModel.currentHunkIndex + 1)/\(viewModel.totalHunks)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)

                    Button(action: { viewModel.nextHunk() }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.currentHunkIndex >= viewModel.totalHunks - 1)
                }
            }

            Divider().frame(height: 16)

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
                    Image(systemName: mode.symbol)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 80)

            Divider().frame(height: 16)

            // Review actions
            Button(action: { viewModel.sendToAgent() }) {
                Image(systemName: "paperplane")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Send review to agent")

            Button(action: { viewModel.copyReview() }) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Copy review to clipboard")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
    }

    // MARK: - Binary / Empty

    private func binaryFileView(_ diff: GitFileDiff) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.zipper")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Binary file")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(diff.fileName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyDiffView: some View {
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
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(viewModel.selectedLineIDs.count) lines selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            Button("Comment") { viewModel.commentOnSelection() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button("Clear") { viewModel.clearSelection() }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
    }
}
