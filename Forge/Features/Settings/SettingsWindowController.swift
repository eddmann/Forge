import AppKit
import Combine
import SwiftUI

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var cancellable: AnyCancellable?

    private init() {
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.minSize = NSSize(width: 640, height: 460)
        window.center()
        window.appearance = TerminalAppearanceStore.shared.config.theme.nsAppearance

        super.init(window: window)

        cancellable = TerminalAppearanceStore.shared.$config
            .map(\.theme)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.window?.appearance = theme.nsAppearance
            }
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showSettings() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
