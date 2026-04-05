import AppKit
import Combine

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()

    // MARK: - Model

    enum Severity {
        case success, warning, error
    }

    struct Action {
        let label: String
        let handler: () -> Void
    }

    struct Toast: Identifiable {
        let id = UUID()
        let message: String
        let severity: Severity
        let action: Action?
        let duration: TimeInterval
    }

    // MARK: - Published State

    @Published private(set) var currentToast: Toast?

    // MARK: - Private

    private var dismissTask: DispatchWorkItem?

    private init() {}

    // MARK: - API

    func show(_ message: String, severity: Severity = .success, duration: TimeInterval? = nil, action: Action? = nil) {
        dismissTask?.cancel()

        let effectiveDuration = duration ?? (severity == .error ? 5.0 : 3.0)
        let toast = Toast(message: message, severity: severity, action: action, duration: effectiveDuration)
        currentToast = toast

        ToastPanel.shared.present()

        let task = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration, execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentToast = nil
        ToastPanel.shared.hide()
    }
}
