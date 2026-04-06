import AppKit
import Combine
import SwiftUI

@MainActor
final class ModalToastPanel {
    static let shared = ModalToastPanel()

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

        guard let mainWindow = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        let mainFrame = mainWindow.frame

        let panel = NSPanel(
            contentRect: mainFrame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.appearance = TerminalAppearanceStore.shared.config.theme.nsAppearance

        let rootView = ZStack {
            Color.black.opacity(0.35)
            ModalToastView()
        }
        .ignoresSafeArea()
        let overlayView = NSHostingController(rootView: rootView)
        overlayView.view.frame = panel.contentView?.bounds ?? .zero
        overlayView.view.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(overlayView.view)

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
        panel.setFrame(main.frame, display: true)
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
