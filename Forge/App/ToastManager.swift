import AppKit
import Combine
import SwiftUI

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
    @Published private(set) var modalToast: Toast?
    @Published private(set) var modalStreamLines: [String] = []

    private let maxStreamLines = 5

    // MARK: - Private

    private var dismissTask: DispatchWorkItem?

    private init() {}

    // MARK: - Regular Toast API

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

    // MARK: - Modal Toast API

    func showModal(_ message: String, severity: Severity = .success) {
        let toast = Toast(message: message, severity: severity, action: nil, duration: 0)
        modalToast = toast
        modalStreamLines = []
        ModalToastPanel.shared.present()
    }

    func appendModalStreamLine(_ line: String) {
        withAnimation(.easeInOut(duration: 0.12)) {
            modalStreamLines.append(line)
            if modalStreamLines.count > maxStreamLines {
                modalStreamLines.removeFirst(modalStreamLines.count - maxStreamLines)
            }
        }
    }

    func dismissModal() {
        modalToast = nil
        modalStreamLines = []
        ModalToastPanel.shared.hide()
    }
}
