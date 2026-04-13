import SwiftUI

struct ModalToastView: View {
    @ObservedObject private var manager = ToastManager.shared

    var body: some View {
        ZStack {
            if let toast = manager.modalToast {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)

                        Text(toast.message)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

                    if !manager.modalStreamLines.isEmpty {
                        Divider()
                            .padding(.horizontal, 16)

                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(
                                Array(manager.modalStreamLines.enumerated()),
                                id: \.offset
                            ) { index, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .opacity(lineOpacity(for: index, of: manager.modalStreamLines.count))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }
                .frame(minWidth: 280, maxWidth: 480)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 20, y: 4)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: toast.id)
                .animation(.easeInOut(duration: 0.15), value: manager.modalStreamLines.count)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lineOpacity(for index: Int, of total: Int) -> Double {
        guard total > 1 else { return 1.0 }
        let position = Double(total - 1 - index)
        return max(0.3, 1.0 - position * 0.2)
    }
}
