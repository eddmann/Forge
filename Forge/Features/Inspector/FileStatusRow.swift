import SwiftUI

struct FileStatusRow: View {
    let file: FileStatus
    let group: WorkingTreeGroup
    let commentCount: Int
    let onSelect: () -> Void
    let onStageToggle: () -> Void
    let onDiscard: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Change type icon
            Image(systemName: file.displayChangeType.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(file.displayChangeType.color)
                .frame(width: 18)

            // File info
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Comment count badge
            if commentCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 9))
                    Text("\(commentCount)")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }

            // Hover action buttons
            if isHovered {
                HStack(spacing: 2) {
                    Button(action: onStageToggle) {
                        Image(systemName: stageSymbol)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help(stageHelp)

                    if let onDiscard {
                        Button(action: onDiscard) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("Discard changes")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isHovered ? Color.white.opacity(0.04) : .clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(group == .staged ? "Unstage" : "Stage") { onStageToggle() }
            if let onDiscard {
                Divider()
                Button("Discard Changes", role: .destructive) { onDiscard() }
            }
        }
    }

    private var stageSymbol: String {
        group == .staged ? "minus.circle" : "plus.circle"
    }

    private var stageHelp: String {
        group == .staged ? "Unstage" : "Stage"
    }
}
