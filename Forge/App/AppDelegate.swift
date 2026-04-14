import AppKit
import CoreText
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    var mainWindowController: MainWindowController?

    private var agentSubmenu: NSMenu!
    private var openRecentSubmenu: NSMenu!
    private var openInEditorSubmenu: NSMenu!
    private var windowTabMenu: NSMenu!
    private let windowMenuStaticItemCount = 3 // Minimize, Zoom, separator

    func applicationDidFinishLaunching(_: Notification) {
        registerBundledFonts()
        setupMainMenu()

        #if DEBUG
            if let demoMode = DemoMode.fromArguments() {
                ProjectStore.shared.isDemo = true
                DemoStateFactory.configure(for: demoMode)
            }
        #endif

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        #if DEBUG
            if let size = DemoMode.windowSize(), let window = mainWindowController?.window {
                window.setFrameAutosaveName("")
                window.setContentSize(NSSize(width: size.width, height: size.height))
                window.center()
            }
        #endif

        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let window = mainWindowController?.window {
            StatusBarController.shared.configure(window: window)
        }

        // Set up notification center delegate for handling taps on system notifications
        UNUserNotificationCenter.current().delegate = self

        #if DEBUG
            if ProjectStore.shared.isDemo { return }
        #endif

        // Prevent macOS from force-killing the app before session save completes
        ProcessInfo.processInfo.disableSuddenTermination()

        // Start socket server for CLI communication
        ForgeSocketServer.shared.start()

        // Watch each project/workspace's .git/HEAD so branch/dirty state stays
        // fresh when the user commits or switches branches outside Forge.
        WorkspaceGitWatcher.shared.start(store: ProjectStore.shared)

        // Write shell integration scripts for scrollback restore
        ShellEnvironment.ensureShellIntegration()

        // Install agent hooks/config/extensions
        DispatchQueue.main.async {
            AgentSetup.shared.installAll()
        }

        // Ensure `forge` CLI symlink points to this app's bundled binary
        #if !DEBUG
            DispatchQueue.global(qos: .utility).async {
                ForgeCLIInstaller.ensureInstalled()
            }
        #endif

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
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            StatusBarController.shared.showWindow()
        }
        return false
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
            if ProjectStore.shared.isDemo { return .terminateNow }
        #endif
        ForgeSocketServer.shared.stop()
        saveSessionSnapshot()
        return .terminateNow
    }

    private func saveSessionSnapshot() {
        MainActor.assumeIsolated {
            TerminalSessionManager.shared.persistState(includeScrollback: true)
            ActivityLogStore.shared.saveImmediately()
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(buildAppMenu())
        mainMenu.addItem(buildFileMenu())
        mainMenu.addItem(buildEditMenu())
        mainMenu.addItem(buildViewMenu())
        mainMenu.addItem(buildWindowMenu())
        NSApplication.shared.mainMenu = mainMenu
    }

    private func buildAppMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(withTitle: "About Forge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Forge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Forge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private func buildFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        // New tabs
        menu.addItem(withTitle: "New Tab", action: #selector(newTab(_:)), keyEquivalent: "t")
        let agentTabItem = NSMenuItem(title: "New Tab with Agent", action: nil, keyEquivalent: "t")
        agentTabItem.keyEquivalentModifierMask = [.command, .shift]
        agentSubmenu = NSMenu()
        agentSubmenu.delegate = self
        agentTabItem.submenu = agentSubmenu
        menu.addItem(agentTabItem)

        menu.addItem(.separator())

        // Close operations
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTab(_:)), keyEquivalent: "w")
        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(closePane(_:)), keyEquivalent: "w")
        closePaneItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(closePaneItem)
        let closeWindowItem = NSMenuItem(title: "Close Window", action: #selector(closeWindow(_:)), keyEquivalent: "w")
        closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(closeWindowItem)

        menu.addItem(.separator())

        // Project operations
        let openProjectItem = NSMenuItem(title: "Open Project…", action: #selector(openProject(_:)), keyEquivalent: "o")
        openProjectItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(openProjectItem)
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        openRecentSubmenu = NSMenu()
        openRecentSubmenu.delegate = self
        recentItem.submenu = openRecentSubmenu
        menu.addItem(recentItem)

        menu.addItem(.separator())

        // Open in external apps
        menu.addItem(withTitle: "Open in Finder", action: #selector(openInFinder(_:)), keyEquivalent: "")
        let editorItem = NSMenuItem(title: "Open in Editor", action: nil, keyEquivalent: "")
        openInEditorSubmenu = NSMenu()
        openInEditorSubmenu.delegate = self
        editorItem.submenu = openInEditorSubmenu
        menu.addItem(editorItem)
        menu.addItem(withTitle: "Copy Project Path", action: #selector(copyProjectPath(_:)), keyEquivalent: "")

        item.submenu = menu
        return item
    }

    private func buildEditMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find…", action: Selector(("findInTerminal:")), keyEquivalent: "f")
        item.submenu = menu
        return item
    }

    private func buildViewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        // Panels
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(MainSplitViewController.toggleLeftSidebar(_:)), keyEquivalent: "0")
        menu.addItem(toggleSidebarItem)
        let toggleInspectorItem = NSMenuItem(title: "Toggle Inspector", action: #selector(MainSplitViewController.toggleRightSidebar(_:)), keyEquivalent: "0")
        toggleInspectorItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggleInspectorItem)

        menu.addItem(.separator())

        // Pane splitting
        menu.addItem(withTitle: "Split Pane Vertically", action: #selector(splitVertical(_:)), keyEquivalent: "d")
        let splitHItem = NSMenuItem(title: "Split Pane Horizontally", action: #selector(splitHorizontal(_:)), keyEquivalent: "d")
        splitHItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(splitHItem)

        menu.addItem(.separator())

        // Pane and tab navigation
        menu.addItem(withTitle: "Next Pane", action: #selector(focusNextPane(_:)), keyEquivalent: "]")
        menu.addItem(withTitle: "Previous Pane", action: #selector(focusPreviousPane(_:)), keyEquivalent: "[")
        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab(_:)), keyEquivalent: "]")
        nextTabItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(nextTabItem)
        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(previousTab(_:)), keyEquivalent: "[")
        prevTabItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prevTabItem)

        menu.addItem(.separator())

        // Font size
        menu.addItem(withTitle: "Bigger", action: #selector(makeFontBigger(_:)), keyEquivalent: "=")
        let biggerNumpad = NSMenuItem(title: "Bigger", action: #selector(makeFontBigger(_:)), keyEquivalent: "+")
        biggerNumpad.isHidden = true
        menu.addItem(biggerNumpad)
        menu.addItem(withTitle: "Smaller", action: #selector(makeFontSmaller(_:)), keyEquivalent: "-")
        menu.addItem(withTitle: "Reset Font Size", action: #selector(resetFontSize(_:)), keyEquivalent: "")

        menu.addItem(.separator())

        // Full screen
        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreenItem)

        item.submenu = menu
        return item
    }

    private func buildWindowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // Dynamic tab list and Bring All to Front are added in menuNeedsUpdate

        menu.delegate = self
        windowTabMenu = menu
        item.submenu = menu
        NSApplication.shared.windowsMenu = menu

        return item
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === agentSubmenu {
            rebuildAgentMenu(menu)
        } else if menu === openRecentSubmenu {
            rebuildOpenRecentMenu(menu)
        } else if menu === openInEditorSubmenu {
            rebuildOpenInEditorMenu(menu)
        } else if menu === windowTabMenu {
            rebuildWindowTabList(menu)
        }
    }

    private func rebuildAgentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        MainActor.assumeIsolated {
            let installed = AgentStore.shared.agents.filter(\.isInstalled)
            if installed.isEmpty {
                let placeholder = NSMenuItem(title: "No Agents Available", action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                menu.addItem(placeholder)
                return
            }
            for agent in installed {
                let item = NSMenuItem(title: agent.name, action: #selector(newTabWithAgent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = agent
                item.image = agent.nsImage(size: 14)
                menu.addItem(item)
            }
        }
    }

    private func rebuildOpenRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let projects = ProjectStore.shared.projects
            .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
            .prefix(10)

        if projects.isEmpty {
            let placeholder = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return
        }

        for project in projects {
            let item = NSMenuItem(title: project.name, action: #selector(openRecentProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = project.id
            menu.addItem(item)
        }
    }

    private func rebuildOpenInEditorMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let editors = ProjectStore.shared.availableEditors

        if editors.isEmpty {
            let placeholder = NSMenuItem(title: "No Editors Found", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return
        }

        for editor in editors {
            let item = NSMenuItem(title: editor.name, action: #selector(openInEditorAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = editor.command
            menu.addItem(item)
        }
    }

    private func rebuildWindowTabList(_ menu: NSMenu) {
        // Remove everything after the static items (Minimize, Zoom, separator)
        while menu.items.count > windowMenuStaticItemCount {
            menu.removeItem(at: windowMenuStaticItemCount)
        }

        MainActor.assumeIsolated {
            let mgr = TerminalSessionManager.shared
            let tabs = mgr.visibleTabs

            for (index, tab) in tabs.enumerated() {
                let item = NSMenuItem(title: tab.title, action: #selector(switchToTab(_:)), keyEquivalent: index < 9 ? "\(index + 1)" : "")
                item.target = self
                item.tag = index + 1
                if tab.id == mgr.activeTabID {
                    item.state = .on
                }
                menu.addItem(item)
            }

            if !tabs.isEmpty {
                menu.addItem(.separator())
            }
        }

        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            let mgr = TerminalSessionManager.shared
            let store = ProjectStore.shared
            let appearance = TerminalAppearanceStore.shared

            switch menuItem.action {
            case #selector(closeTab(_:)):
                return mgr.activeTabID != nil
            case #selector(closePane(_:)):
                return (mgr.activeTab?.paneManager?.paneCount ?? 1) > 1
            case #selector(closeWindow(_:)):
                return NSApp.mainWindow?.isVisible == true
            case #selector(openInFinder(_:)), #selector(copyProjectPath(_:)):
                return store.effectivePath != nil
            case #selector(splitVertical(_:)), #selector(splitHorizontal(_:)):
                return mgr.activeTab?.kind.isTerminal == true
            case #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)):
                return (mgr.activeTab?.paneManager?.paneCount ?? 1) > 1
            case #selector(makeFontBigger(_:)):
                return appearance.config.fontSize < 24
            case #selector(makeFontSmaller(_:)):
                return appearance.config.fontSize > 10
            case #selector(resetFontSize(_:)):
                return appearance.config.fontSize != 16
            case #selector(toggleFullScreen(_:)):
                let isFS = NSApp.mainWindow?.styleMask.contains(.fullScreen) == true
                menuItem.title = isFS ? "Exit Full Screen" : "Enter Full Screen"
                return NSApp.mainWindow != nil
            default:
                return true
            }
        }
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
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let tabIDString = userInfo["tabID"] as? String,
                   let tabID = UUID(uuidString: tabIDString)
                {
                    TerminalSessionManager.shared.activateTab(id: tabID)
                    AgentEventStore.shared.markRead(tabID: tabID)
                }
                StatusBarController.shared.showWindow()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner even when app is in foreground (but our suppression logic in AgentEventStore
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

    @objc func newTabWithAgent(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard var agent = sender.representedObject as? AgentConfig else { return }
            let store = ProjectStore.shared
            if let pid = store.activeProjectID {
                agent = agent.applying(projectID: pid)
            }
            let dir = store.effectivePath ?? NSHomeDirectory()
            TerminalSessionManager.shared.createSession(
                workingDirectory: dir,
                title: agent.name,
                launchCommand: agent.fullCommand,
                closeOnExit: true,
                projectID: store.activeProjectID,
                workspaceID: store.activeWorkspaceID,
                icon: agent.icon
            )
        }
    }

    @objc func closeWindow(_: Any?) {
        MainActor.assumeIsolated {
            StatusBarController.shared.hideWindow()
        }
    }

    @objc func openRecentProject(_ sender: NSMenuItem) {
        guard let projectID = sender.representedObject as? UUID else { return }
        ProjectStore.shared.activeProjectID = projectID
        ProjectStore.shared.activeWorkspaceID = nil
    }

    @objc func openInFinder(_: Any?) {
        guard let path = ProjectStore.shared.effectivePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func openInEditorAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String,
              let path = ProjectStore.shared.effectivePath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command, path]
        try? process.run()
    }

    @objc func copyProjectPath(_: Any?) {
        guard let path = ProjectStore.shared.effectivePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc func makeFontBigger(_: Any?) {
        MainActor.assumeIsolated {
            let store = TerminalAppearanceStore.shared
            store.config.fontSize = min(store.config.fontSize + 1, 24)
        }
    }

    @objc func makeFontSmaller(_: Any?) {
        MainActor.assumeIsolated {
            let store = TerminalAppearanceStore.shared
            store.config.fontSize = max(store.config.fontSize - 1, 10)
        }
    }

    @objc func resetFontSize(_: Any?) {
        MainActor.assumeIsolated {
            TerminalAppearanceStore.shared.config.fontSize = 16
        }
    }

    @objc func toggleFullScreen(_: Any?) {
        NSApp.mainWindow?.toggleFullScreen(nil)
    }
}
