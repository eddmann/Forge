import SwiftUI

struct WorkspaceDiffList: View {
    @ObservedObject private var viewModel = WorkspaceDiffViewModel.shared

    @State private var commitsExpanded = true
    @State private var filesExpanded = true

    var body: some View {
        if viewModel.isLoading, viewModel.fileDiffs.isEmpty {
            VStack {
                Spacer()
                ProgressView("Loading workspace changes...")
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
                    .padding(.horizontal, 16)
                Button("Retry") { viewModel.refresh() }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.fileDiffs.isEmpty, viewModel.commits.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 24))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                Text("No workspace changes")
                    .font(.system(size: 13))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    statsHeader
                    commitsSection
                    filesSection
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        HStack(spacing: 8) {
            if let stats = viewModel.stats {
                Label("\(stats.filesChanged)", systemImage: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack(spacing: 2) {
                    Text("+\(stats.insertions)")
                        .foregroundColor(.green)
                    Text("-\(stats.deletions)")
                        .foregroundColor(.red)
                }
                .font(.system(size: 11, design: .monospaced))
            }

            if !viewModel.commits.isEmpty {
                Label("\(viewModel.commits.count)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - Commits Section

    @ViewBuilder
    private var commitsSection: some View {
        if !viewModel.commits.isEmpty {
            sectionHeader(
                title: "Commits",
                count: viewModel.commits.count,
                expanded: $commitsExpanded
            )

            if commitsExpanded {
                ForEach(viewModel.commits) { commit in
                    WorkspaceCommitRow(commit: commit)
                }
            }
        }
    }

    // MARK: - Files Section

    @ViewBuilder
    private var filesSection: some View {
        if !viewModel.fileDiffs.isEmpty {
            sectionHeader(
                title: "Changed Files",
                count: viewModel.fileDiffs.count,
                expanded: $filesExpanded
            )

            if filesExpanded {
                ForEach(viewModel.fileDiffs) { fileDiff in
                    WorkspaceFileRow(
                        fileDiff: fileDiff,
                        isSelected: viewModel.selectedFilePath == (fileDiff.newPath ?? fileDiff.oldPath),
                        onSelect: {
                            viewModel.selectFile(fileDiff.newPath ?? fileDiff.oldPath ?? "")
                        }
                    )
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, count: Int, expanded: Binding<Bool>) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() } }) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Text("\(count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(3)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Commit Row

private struct WorkspaceCommitRow: View {
    let commit: WorkspaceCommit

    @State private var isHovered = false

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(commit.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.accentColor)

            Text(commit.message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(Self.dateFormatter.localizedString(for: commit.date, relativeTo: Date()))
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isHovered ? Color.white.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - File Row

private struct WorkspaceFileRow: View {
    let fileDiff: GitFileDiff
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: changeSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(changeColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(fileDiff.fileName)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !fileDiff.directory.isEmpty {
                    Text(fileDiff.directory)
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if fileDiff.additions > 0 {
                    Text("+\(fileDiff.additions)")
                        .foregroundColor(.green)
                }
                if fileDiff.deletions > 0 {
                    Text("-\(fileDiff.deletions)")
                        .foregroundColor(.red)
                }
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.15)
                : (isHovered ? Color.white.opacity(0.04) : .clear)
        )
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }

    private var changeSymbol: String {
        switch fileDiff.change {
        case .added: "plus.circle.fill"
        case .modified: "pencil.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        }
    }

    private var changeColor: Color {
        switch fileDiff.change {
        case .added: .green
        case .modified: .orange
        case .deleted: .red
        case .renamed: .blue
        case .copied: .cyan
        }
    }
}
