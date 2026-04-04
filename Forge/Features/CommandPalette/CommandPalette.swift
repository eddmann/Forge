import AppKit
import SwiftUI

@MainActor
final class CommandPalette {
    static let shared = CommandPalette()

    private var panel: NSPanel?
    private var eventMonitor: Any?
    private let viewModel = CommandPaletteViewModel()

    private init() {}

    func toggle(from window: NSWindow?) {
        if let panel, panel.isVisible {
            close()
        } else {
            show(from: window)
        }
    }

    func show(from window: NSWindow?) {
        guard let window else { return }
        close()

        viewModel.activate()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        let theme = TerminalAppearanceStore.shared.config.theme
        panel.appearance = theme.nsAppearance
        panel.backgroundColor = theme.popoverBackground
        panel.hasShadow = true

        let f = window.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - 260, y: f.midY + 20))

        let host = NSHostingController(
            rootView: CommandPaletteView(viewModel: viewModel, onClose: { [weak self] in
                self?.close()
            })
        )
        panel.contentView = host.view
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }
            switch event.keyCode {
            case 53: close(); return nil
            case 125: viewModel.moveSelection(by: 1); return nil
            case 126: viewModel.moveSelection(by: -1); return nil
            case 36, 76:
                close()
                viewModel.executeSelected()
                return nil
            default: return event
            }
        }
    }

    func close() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        panel?.close()
        panel = nil
    }
}
