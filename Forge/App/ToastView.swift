import SwiftUI

struct ToastView: View {
    @ObservedObject private var manager = ToastManager.shared

    var body: some View {
        if let toast = manager.currentToast {
            HStack(spacing: 8) {
                Image(systemName: iconName(for: toast.severity))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(iconColor(for: toast.severity))

                Text(toast.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if let action = toast.action {
                    Spacer(minLength: 4)

                    Button(action.label) {
                        action.handler()
                        manager.dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: 340)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor(for: toast.severity), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: manager.currentToast?.id)
        }
    }

    private func iconName(for severity: ToastManager.Severity) -> String {
        switch severity {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.circle.fill"
        }
    }

    private func iconColor(for severity: ToastManager.Severity) -> Color {
        switch severity {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    private func borderColor(for severity: ToastManager.Severity) -> Color {
        switch severity {
        case .success: Color.green.opacity(0.2)
        case .warning: Color.orange.opacity(0.2)
        case .error: Color.red.opacity(0.2)
        }
    }
}
