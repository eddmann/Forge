import AppKit
import CoreText
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_: Notification) {
        registerBundledFonts()
        setupMainMenu()
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Set up notification center delegate for handling taps on system notifications
        UNUserNotificationCenter.current().delegate = self

        // Prevent macOS from force-killing the app before session save completes
        ProcessInfo.processInfo.disableSuddenTermination()

        // Start socket server for CLI communication
        ForgeSocketServer.shared.start()

        // Write shell integration scripts for scrollback restore
        ShellEnvironment.ensureShellIntegration()

        // Offer to install forge CLI and agent status hooks
        DispatchQueue.main.async {
            ForgeCLIInstaller.installIfNeeded()
            AgentHookInstaller.installIfNeeded()
        }

        // Global Cmd+K for command palette
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags == .command, key == "k" {
                CommandPalette.shared.toggle(from: NSApp.mainWindow)
                return nil
            }
            return event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openProject(_:)),
            name: .openProjectRequested,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        ForgeSocketServer.shared.stop()
        saveSessionSnapshot()
        return .terminateNow
    }

    private func saveSessionSnapshot() {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.persistState(includeScrollback: true)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Forge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Forge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Forge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        let openProjectItem = NSMenuItem(title: "Open Project…", action: #selector(openProject(_:)), keyEquivalent: "o")
        openProjectItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openProjectItem)
        fileMenuItem.submenu = fileMenu

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Shell menu (split panes)
        let shellMenuItem = NSMenuItem()
        mainMenu.addItem(shellMenuItem)
        let shellMenu = NSMenu(title: "Shell")

        shellMenu.addItem(withTitle: "Split Pane Vertically", action: #selector(splitVertical(_:)), keyEquivalent: "d")
        let splitHItem = NSMenuItem(title: "Split Pane Horizontally", action: #selector(splitHorizontal(_:)), keyEquivalent: "d")
        splitHItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(splitHItem)
        shellMenu.addItem(.separator())

        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(closePane(_:)), keyEquivalent: "w")
        closePaneItem.keyEquivalentModifierMask = [.command, .option]
        shellMenu.addItem(closePaneItem)
        shellMenu.addItem(.separator())

        shellMenu.addItem(withTitle: "Next Pane", action: #selector(focusNextPane(_:)), keyEquivalent: "]")
        shellMenu.addItem(withTitle: "Previous Pane", action: #selector(focusPreviousPane(_:)), keyEquivalent: "[")

        shellMenuItem.submenu = shellMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(MainSplitViewController.toggleLeftSidebar(_:)), keyEquivalent: "0")
        viewMenu.addItem(toggleSidebarItem)
        let toggleInspectorItem = NSMenuItem(title: "Toggle Inspector", action: #selector(MainSplitViewController.toggleRightSidebar(_:)), keyEquivalent: "0")
        toggleInspectorItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleInspectorItem)
        viewMenuItem.submenu = viewMenu

        // Window menu (tab switching)
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())

        // Tab switching: Cmd+1 through Cmd+9
        for i in 1 ... 9 {
            let item = NSMenuItem(title: "Tab \(i)", action: #selector(switchToTab(_:)), keyEquivalent: "\(i)")
            item.tag = i
            windowMenu.addItem(item)
        }
        windowMenu.addItem(.separator())

        let prevTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevTabItem)

        let nextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextTabItem)

        windowMenuItem.submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu

        // Help menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        NSApplication.shared.helpMenu = helpMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    private func registerBundledFonts() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents where fileURL.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, nil)
        }
    }

    @objc func showSettings(_: Any?) {
        SettingsWindowController.shared.showSettings()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let tabIDString = userInfo["tabID"] as? String,
           let tabID = UUID(uuidString: tabIDString)
        {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    TerminalSessionManager.shared.activateTab(id: tabID)
                }
                NotificationStore.shared.markRead(tabID: tabID)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        completionHandler()
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner even when app is in foreground (but our suppression logic in NotificationStore
        // already avoids sending system notifications for the focused tab)
        completionHandler([.banner, .sound])
    }

    // MARK: - Terminal Menu Actions

    // These live on AppDelegate so they're always reachable via the responder
    // chain regardless of which view has focus.

    @objc func newTab(_: Any?) {
        MainActor.assumeIsolated {
            let store = ProjectStore.shared
            let dir = store.effectivePath ?? NSHomeDirectory()
            TerminalSessionManager.shared.createSession(
                workingDirectory: dir,
                projectID: store.activeProjectID,
                workspaceID: store.activeWorkspaceID
            )
        }
    }

    @objc func closeTab(_: Any?) {
        MainActor.assumeIsolated {
            guard let activeID = TerminalSessionManager.shared.activeTabID else { return }
            TerminalSessionManager.shared.closeTab(id: activeID)
        }
    }

    @objc func switchToTab(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.activateTab(at: sender.tag - 1)
        }
    }

    @objc func previousTab(_: Any?) {
        MainActor.assumeIsolated {
            guard let current = TerminalSessionManager.shared.activeTabIndex(), current > 0 else { return }
            TerminalSessionManager.shared.activateTab(at: current - 1)
        }
    }

    @objc func nextTab(_: Any?) {
        MainActor.assumeIsolated {
            let mgr = TerminalSessionManager.shared
            guard let current = mgr.activeTabIndex(),
                  current < mgr.visibleTabs.count - 1 else { return }
            mgr.activateTab(at: current + 1)
        }
    }

    @objc func splitVertical(_: Any?) {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.splitFocusedPane(axis: .vertical)
        }
    }

    @objc func splitHorizontal(_: Any?) {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.splitFocusedPane(axis: .horizontal)
        }
    }

    @objc func closePane(_: Any?) {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.closeFocusedPane()
        }
    }

    @objc func focusNextPane(_: Any?) {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.focusNextPane()
        }
    }

    @objc func focusPreviousPane(_: Any?) {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.focusPreviousPane()
        }
    }

    @objc func openProject(_: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        panel.prompt = "Open"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                ProjectStore.shared.addProject(from: url)
            }
        }
    }
}
