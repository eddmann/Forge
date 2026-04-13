import SwiftUI

// MARK: - DiffCommentHost

/// Protocol abstracting comment operations shared by DiffViewModel and ChangesViewModel.
@MainActor
protocol DiffCommentHost: ObservableObject {
    var draftComment: DraftCommentState? { get set }
    func editComment(_ comment: AgentReviewComment)
    func deleteComment(_ comment: AgentReviewComment)
    func cancelDraft()
    func saveDraft()
}

extension DiffViewModel: DiffCommentHost {}
extension ChangesViewModel: DiffCommentHost {}

// MARK: - Inline Comment Card

struct DiffInlineCommentCard<Host: DiffCommentHost>: View {
    let comment: AgentReviewComment
    @ObservedObject var viewModel: Host
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

                Text(comment.text.trimmingCharacters(in: .whitespacesAndNewlines))
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

struct DiffInlineDraftEditor<Host: DiffCommentHost>: View {
    @ObservedObject var viewModel: Host
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
    }
}
