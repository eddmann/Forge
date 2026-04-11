import AppKit
import Combine
import SwiftUI

@MainActor
final class ModalToastPanel {
    static let shared = ModalToastPanel()

    private var hostingView: NSView?
    private weak var attachedWindow: NSWindow?

    private init() {}

    func present() {
        if hostingView != nil { return }

        guard let window = NSApp.mainWindow ?? NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let rootView = ZStack {
            Color.black.opacity(0.35)
            ModalToastView()
        }
        .ignoresSafeArea()

        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        hostingView = host
        attachedWindow = window
    }

    func hide() {
        hostingView?.removeFromSuperview()
        hostingView = nil
        attachedWindow = nil
    }
}
