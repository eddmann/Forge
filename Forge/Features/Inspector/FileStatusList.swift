import SwiftUI

struct FileStatusList: View {
    @ObservedObject private var viewModel = StatusViewModel.shared
    @ObservedObject private var reviewStore = ReviewStore.shared

    @State private var pendingDiscard: (file: FileStatus, group: WorkingTreeGroup)?
    @State private var showDiscardConfirmation = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if viewModel.statuses.isEmpty, !viewModel.isLoading {
                    emptyState
                } else {
                    // File sections
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            section(for: .conflicts)
                            section(for: .staged)
                            section(for: .unstaged)
                            section(for: .untracked)
                        }
                        .padding(.top, 4)
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)

                    // Commit composer
                    commitComposer
                }
            }

            // Toast notification overlay
            if let msg = viewModel.feedbackMessage {
                GitToast(message: msg, isError: viewModel.feedbackIsError)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 8)
                    .padding(.horizontal, 8)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.feedbackMessage)
        .confirmationDialog(
            "Discard Changes?",
            isPresented: $showDiscardConfirmation,
            presenting: pendingDiscard
        ) { pending in
            Button("Discard") {
                viewModel.discard(file: pending.file, group: pending.group)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("This will permanently discard changes to \(pending.file.fileName).")
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func section(for group: WorkingTreeGroup) -> some View {
        let files = viewModel.grouped[group] ?? []
        if !files.isEmpty {
            // Section header
            HStack(spacing: 6) {
                Circle()
                    .fill(group.accentColor)
                    .frame(width: 6, height: 6)

                Text(group.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Text("\(files.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)

                Spacer()

                // Bulk action
                Button(action: { bulkAction(for: group) }) {
                    Text(group == .staged ? "Unstage All" : "Stage All")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // File rows
            ForEach(files) { file in
                FileStatusRow(
                    file: file,
                    group: group,
                    isSelected: viewModel.selectedFilePath == file.path,
                    commentCount: fileCommentCount(for: file),
                    onSelect: { viewModel.selectFile(file, staged: group == .staged) },
                    onStageToggle: {
                        if group == .staged {
                            viewModel.unstage(file: file)
                        } else {
                            viewModel.stage(file: file)
                        }
                    },
                    onDiscard: group == .conflicts ? nil : {
                        pendingDiscard = (file, group)
                        showDiscardConfirmation = true
                    }
                )
            }
        }
    }

    // MARK: - Commit Composer

    private var commitComposer: some View {
        VStack(spacing: 8) {
            // Message field
            TextField(viewModel.isAmend ? "Amend commit message..." : "Commit message...",
                      text: $viewModel.commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3 ... 6)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(viewModel.isAmend ? Color.orange.opacity(0.3) : Color(nsColor: .separatorColor), lineWidth: 1)
                )

            // Controls row
            HStack(spacing: 8) {
                // Amend toggle
                Button(action: { viewModel.toggleAmend() }) {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isAmend ? "checkmark.square.fill" : "square")
                            .font(.system(size: 11))
                            .foregroundColor(viewModel.isAmend ? .orange : .secondary)
                        Text("Amend")
                            .font(.system(size: 11))
                            .foregroundColor(viewModel.isAmend ? .orange : .secondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if viewModel.isCommitting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }

                // Commit button
                let hasStaged = !(viewModel.grouped[.staged] ?? []).isEmpty
                let messageEmpty = viewModel.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let canCommit = !messageEmpty && (hasStaged || viewModel.isAmend) && !viewModel.isCommitting

                Button(action: { viewModel.commit() }) {
                    Text(viewModel.isAmend ? "Amend Commit" : "Commit")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(viewModel.isAmend ? .orange : .accentColor)
                .disabled(!canCommit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
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

    // MARK: - Helpers

    private func bulkAction(for group: WorkingTreeGroup) {
        switch group {
        case .staged: viewModel.unstageAll()
        case .unstaged: viewModel.stageAll()
        case .untracked: viewModel.stageAll()
        case .conflicts: break
        }
    }

    private func fileCommentCount(for file: FileStatus) -> Int {
        guard let root = ProjectStore.shared.effectiveRootPath else { return 0 }
        return reviewStore.comments(in: root, filePath: file.path).count
    }
}

// MARK: - Toast Notification

private struct GitToast: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isError ? .red : .green)

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isError ? Color.red.opacity(0.2) : Color.green.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}
