import AppKit
import Combine
import SwiftUI

@MainActor
final class ToastPanel {
    static let shared = ToastPanel()

    private var panel: NSPanel?
    private var windowObservers: [Any] = []
    private var themeCancellable: AnyCancellable?

    private init() {
        themeCancellable = TerminalAppearanceStore.shared.$config
            .map(\.theme)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.panel?.appearance = theme.nsAppearance
            }
    }

    func present() {
        if let panel, panel.isVisible {
            reposition(panel)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 50),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hasShadow = false // SwiftUI view provides its own shadow
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = TerminalAppearanceStore.shared.config.theme.nsAppearance

        let host = NSHostingController(rootView: ToastView())
        host.view.frame = panel.contentView?.bounds ?? .zero
        host.view.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host.view)

        reposition(panel)
        panel.orderFront(nil)

        self.panel = panel
        observeMainWindow()
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        removeWindowObservers()
    }

    // MARK: - Positioning

    private func reposition(_ panel: NSPanel) {
        guard let main = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        let mainFrame = main.frame
        let panelSize = panel.frame.size
        let x = mainFrame.midX - panelSize.width / 2
        let y = mainFrame.origin.y + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Window Tracking

    private func observeMainWindow() {
        removeWindowObservers()
        guard let main = NSApp.mainWindow ?? NSApp.keyWindow else { return }

        let moveObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: main, queue: .main
        ) { [weak self] _ in
            if let panel = self?.panel { self?.reposition(panel) }
        }
        let resizeObs = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: main, queue: .main
        ) { [weak self] _ in
            if let panel = self?.panel { self?.reposition(panel) }
        }
        windowObservers = [moveObs, resizeObs]
    }

    private func removeWindowObservers() {
        for obs in windowObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowObservers = []
    }
}
