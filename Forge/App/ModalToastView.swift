import SwiftUI

struct ModalToastView: View {
    @ObservedObject private var manager = ToastManager.shared

    var body: some View {
        ZStack {
            if let toast = manager.modalToast {
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
                .frame(minWidth: 240, maxWidth: 400)
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
