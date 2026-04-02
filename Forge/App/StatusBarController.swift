import AppKit
import Combine

@MainActor
class StatusBarController {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var badgeDot: NSView?
    private var pulseTimer: Timer?
    private var isPulseHigh = true

    // MARK: - Setup

    func configure(window: NSWindow) {
        mainWindow = window

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            let image = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "Forge")
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            button.image = image?.withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Badge dot (hidden by default)
            let dot = NSView(frame: NSRect(x: button.bounds.width - 10, y: button.bounds.height - 10, width: 8, height: 8))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 4
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.isHidden = true
            dot.autoresizingMask = [.minXMargin, .minYMargin]
            button.addSubview(dot)
            badgeDot = dot
        }

        observeActivity()
    }

    // MARK: - Window Visibility

    func showWindow() {
        guard let window = mainWindow else { return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hideWindow() {
        guard let window = mainWindow else { return }
        window.orderOut(nil)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    var isWindowVisible: Bool {
        mainWindow?.isVisible ?? false
    }

    // MARK: - Badge

    func updateBadge(count: Int) {
        badgeDot?.isHidden = count == 0
    }

    // MARK: - Click Handling

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu(from: sender)
        } else {
            toggleWindow()
        }
    }

    private func toggleWindow() {
        if isWindowVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    // MARK: - Menu

    private func showMenu(from _: NSStatusBarButton) {
        let menu = NSMenu()

        // Show/Hide Window
        let windowTitle = isWindowVisible ? "Hide Window" : "Show Window"
        let windowItem = NSMenuItem(title: windowTitle, action: #selector(toggleWindowAction), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)

        menu.addItem(.separator())

        // Active project info
        if let project = ProjectStore.shared.activeProject {
            let projectItem = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
            projectItem.isEnabled = false
            menu.addItem(projectItem)
        }

        // Running agents summary
        let activities = AgentEventStore.shared.activityByTab
        let activeCount = activities.values.filter { $0 != .idle && $0 != .complete }.count
        if activeCount > 0 {
            let agentItem = NSMenuItem(title: "\(activeCount) agent\(activeCount == 1 ? "" : "s") running", action: nil, keyEquivalent: "")
            agentItem.isEnabled = false
            menu.addItem(agentItem)
        }

        let unread = AgentEventStore.shared.totalUnreadCount
        if unread > 0 {
            let unreadItem = NSMenuItem(title: "\(unread) unread notification\(unread == 1 ? "" : "s")", action: nil, keyEquivalent: "")
            unreadItem.isEnabled = false
            menu.addItem(unreadItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Forge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleWindowAction() {
        toggleWindow()
    }

    @objc private func openSettings() {
        // Ensure app is active so Settings window gets focus
        if !isWindowVisible {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        SettingsWindowController.shared.showSettings()
    }

    // MARK: - Activity Pulse

    private func observeActivity() {
        AgentEventStore.shared.$activityByTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activities in
                let hasActive = activities.values.contains { activity in
                    switch activity {
                    case .thinking, .toolExecuting, .retrying, .compacting:
                        true
                    default:
                        false
                    }
                }
                self?.updatePulse(active: hasActive)
            }
            .store(in: &cancellables)
    }

    private func updatePulse(active: Bool) {
        if active {
            guard pulseTimer == nil else { return }
            isPulseHigh = true
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isPulseHigh.toggle()
                    self.statusItem?.button?.alphaValue = self.isPulseHigh ? 1.0 : 0.4
                }
            }
        } else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            statusItem?.button?.alphaValue = 1.0
        }
    }
}
