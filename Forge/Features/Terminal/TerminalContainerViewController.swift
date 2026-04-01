import AppKit
import Combine
import SwiftUI

class TerminalContainerViewController: NSViewController {
    private let sessionManager = TerminalSessionManager.shared
    private let tabBar = TerminalTabBar()
    private let containerView = NSView()
    private var currentHostingView: NSView?
    private var cachedHostingViews: [UUID: NSView] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var clickMonitor: Any?

    // Status bar at bottom — glass effect
    private let statusBar = NSVisualEffectView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let agentInfoStack = NSStackView()
    private var currentCapabilities: AgentCapabilities?
    private var renderedTabID: UUID?

    override func loadView() {
        view = FirstResponderView()
        view.wantsLayer = true

        // Tab bar at top
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        // Container for BonsplitView
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = TerminalAppearanceStore.shared.config.theme.background.cgColor
        view.addSubview(containerView)

        // Status bar at bottom — glass material
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.material = .sidebar
        statusBar.blendingMode = .behindWindow
        statusBar.state = .inactive
        view.addSubview(statusBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusBar.addSubview(statusLabel)

        agentInfoStack.translatesAutoresizingMaskIntoConstraints = false
        agentInfoStack.orientation = .horizontal
        agentInfoStack.spacing = 6
        agentInfoStack.isHidden = true
        statusBar.addSubview(agentInfoStack)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 36),

            containerView.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),

            agentInfoStack.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            agentInfoStack.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])

        setupBindings()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Agent status and notifications driven by ForgeSocketServer via NotificationStore

        let initialProjectID = ProjectStore.shared.activeProjectID
        let initialWorkspaceID = ProjectStore.shared.activeWorkspaceID
        sessionManager.switchProject(to: initialProjectID, workspaceID: initialWorkspaceID)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePaneLayoutChanged),
            name: .paneSplitLayoutChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAgentChanged),
            name: .agentDetectionChanged, object: nil
        )

        // Track pane focus when clicking on terminal views embedded in BonsplitView
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  window == view.window else { return event }
            let loc = event.locationInWindow
            guard let hit = window.contentView?.hitTest(loc) else { return event }
            var v: NSView? = hit
            while let current = v {
                if let term = current as? GhosttyTerminalView, let sid = term.sessionID {
                    sessionManager.setFocusedSession(sid)
                    window.makeFirstResponder(term)
                    break
                }
                v = current.superview
            }
            return event
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Immediately claim first responder for our view so the responder chain
        // includes this controller (enabling Cmd+T, Cmd+W etc.), even before
        // the terminal view is ready.
        view.window?.makeFirstResponder(view)
        makeFocusedTerminalFirstResponder()
    }

    deinit {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
    }

    private func setupBindings() {
        // Show active tab's BonsplitView
        sessionManager.$activeTabID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showActiveTab() }
            .store(in: &cancellables)

        // Update tab bar and status on changes
        sessionManager.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTabBar()
                self?.updateStatusBar()
            }
            .store(in: &cancellables)

        sessionManager.$activeTabID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateTabBar()
                self?.updateStatusBar()
            }
            .store(in: &cancellables)

        sessionManager.$focusedSessionID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.makeFocusedTerminalFirstResponder()
                self?.updateAgentInfo()
            }
            .store(in: &cancellables)

        NotificationStore.shared.$agentStatusByTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTabBar() }
            .store(in: &cancellables)

        NotificationStore.shared.$unreadCountByTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTabBar() }
            .store(in: &cancellables)

        ProjectStore.shared.$activeProjectID
            .combineLatest(ProjectStore.shared.$activeWorkspaceID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] projectID, workspaceID in
                self?.sessionManager.switchProject(to: projectID, workspaceID: workspaceID)
            }
            .store(in: &cancellables)

        // Observe theme changes — update tab bar and container chrome
        TerminalAppearanceStore.shared.$config
            .map(\.theme)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] theme in
                self?.applyTheme(theme)
            }
            .store(in: &cancellables)

        // Tab bar callbacks
        tabBar.onSelectTab = { [weak self] id in
            self?.sessionManager.activateTab(id: id)
            NotificationStore.shared.markRead(tabID: id)
        }
        tabBar.onCloseTab = { [weak self] id in
            self?.sessionManager.closeTab(id: id)
        }
        tabBar.onRenameTab = { [weak self] id, name in
            self?.sessionManager.renameTab(id: id, title: name)
        }
        tabBar.onNewShellTab = { [weak self] in
            let store = ProjectStore.shared
            let dir = store.effectivePath ?? NSHomeDirectory()
            self?.sessionManager.createSession(
                workingDirectory: dir,
                projectID: store.activeProjectID,
                workspaceID: store.activeWorkspaceID
            )
        }
        tabBar.onNewAgentTab = { [weak self] agent in
            let store = ProjectStore.shared
            let dir = store.effectivePath ?? NSHomeDirectory()
            let resolved = store.activeProject.map { agent.applying(projectID: $0.id) } ?? agent
            self?.sessionManager.createSession(
                workingDirectory: dir,
                title: resolved.name,
                launchCommand: resolved.fullCommand,
                closeOnExit: true,
                projectID: store.activeProjectID,
                workspaceID: store.activeWorkspaceID,
                icon: resolved.icon
            )
        }
    }

    // MARK: - Active Tab Display

    private func showActiveTab() {
        // Hide current view (don't destroy — it's cached)
        currentHostingView?.isHidden = true
        currentHostingView = nil
        renderedTabID = nil

        // Evict cached views for closed tabs
        let activeTabIDs = Set(sessionManager.tabs.map(\.id))
        for (tabID, view) in cachedHostingViews where !activeTabIDs.contains(tabID) {
            view.removeFromSuperview()
            cachedHostingViews.removeValue(forKey: tabID)
        }

        guard let tabIndex = sessionManager.tabs.firstIndex(where: { $0.id == sessionManager.activeTabID }) else {
            return
        }

        let tab = sessionManager.tabs[tabIndex]

        switch tab.kind {
        case .terminal:
            showTerminalTab(at: tabIndex)
        case let .changes(repoPath):
            showChangesTab(repoPath: repoPath, tabID: tab.id)
        }

        renderedTabID = sessionManager.activeTabID
    }

    private func showTerminalTab(at tabIndex: Int) {
        let tab = sessionManager.tabs[tabIndex]

        if let cached = cachedHostingViews[tab.id] {
            cached.isHidden = false
            currentHostingView = cached
            makeFocusedTerminalFirstResponder()
            return
        }

        let manager = sessionManager.ensurePaneManager(for: tabIndex)

        let bonsplitContent = BonsplitContentWrapper(manager: manager) { [weak self] sessionID in
            self?.sessionManager.closeSession(id: sessionID)
        }

        let hostingView = NSHostingView(rootView: bonsplitContent)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        cachedHostingViews[tab.id] = hostingView
        currentHostingView = hostingView
        // New tab — terminal view needs a layout pass before it can become first responder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.makeFocusedTerminalFirstResponder()
        }
    }

    private func showChangesTab(repoPath: String, tabID: UUID) {
        if let cached = cachedHostingViews[tabID] {
            cached.isHidden = false
            currentHostingView = cached
            return
        }

        let viewModel = ChangesViewModel(repoPath: repoPath)
        let changesView = ChangesTabView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: changesView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        cachedHostingViews[tabID] = hostingView
        currentHostingView = hostingView
    }

    private func makeFocusedTerminalFirstResponder() {
        // If no session is focused yet (e.g. after restore), pick the first
        // session from the active tab.
        var focused = sessionManager.focusedSessionID
        if focused == nil, let activeTab = sessionManager.visibleTabs.first {
            let sessionID = activeTab.paneManager?.focusedSessionID
                ?? activeTab.sessionIDs.first
            if let sessionID {
                sessionManager.setFocusedSession(sessionID)
                focused = sessionID
            }
        }

        guard let focused,
              let termView = TerminalCache.shared.view(for: focused) else { return }
        claimFirstResponder(for: termView, attempts: 0)
    }

    private func claimFirstResponder(for termView: GhosttyTerminalView, attempts: Int) {
        guard attempts < 10 else { return }
        if let window = termView.window ?? view.window {
            window.makeFirstResponder(termView)
            // Verify it stuck — if not, retry (something else may have stolen it)
            if window.firstResponder !== termView, attempts < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.claimFirstResponder(for: termView, attempts: attempts + 1)
                }
            }
        } else {
            // View not in window yet — retry after layout pass
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.claimFirstResponder(for: termView, attempts: attempts + 1)
            }
        }
    }

    // MARK: - Tab Bar & Status

    private func updateTabBar() {
        tabBar.update(
            tabs: sessionManager.visibleTabs,
            activeID: sessionManager.activeTabID,
            agentStatuses: NotificationStore.shared.agentStatusByTab,
            notificationCounts: NotificationStore.shared.unreadCountByTab
        )
    }

    private func applyTheme(_ theme: TerminalTheme) {
        tabBar.refreshTheme()
        containerView.layer?.backgroundColor = theme.background.cgColor
        updateTabBar()
    }

    private func updateStatusBar() {
        statusLabel.stringValue = ""
        updateAgentInfo()
    }

    private func updateAgentInfo() {
        let focusedID = sessionManager.focusedSessionID
        let processName = focusedID.flatMap { id in
            AgentDetector.shared.detectAgent(sessionID: id)
        }

        guard let processName,
              let agent = AgentStore.shared.agents.first(where: { $0.command == processName }),
              let projectPath = ProjectStore.shared.effectiveRootPath ?? ProjectStore.shared.activeProject?.path
        else {
            agentInfoStack.isHidden = true
            currentCapabilities = nil
            return
        }

        let caps = AgentCapabilityParser.parse(agent: agent, projectPath: projectPath)
        currentCapabilities = caps

        agentInfoStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let enabledPlugins = caps.plugins.filter(\.enabled)
        let mc = caps.mcpServers.count
        let sc = caps.skills.count
        let pc = enabledPlugins.count
        let ic = caps.instructions.count
        let items: [(String, Int, Int)] = [
            (mc == 1 ? "MCP" : "MCPs", mc, 0),
            (sc == 1 ? "skill" : "skills", sc, 1),
            (pc == 1 ? "plugin" : "plugins", pc, 2),
            (ic == 1 ? "instruction" : "instructions", ic, 3)
        ]

        let visibleItems = items.filter { $0.1 > 0 }
        guard !visibleItems.isEmpty else {
            agentInfoStack.isHidden = true
            return
        }

        if let iconImage = agent.nsImage(size: 11) {
            let iconView = NSImageView(image: iconImage)
            iconView.contentTintColor = .secondaryLabelColor
            iconView.toolTip = agent.name
            agentInfoStack.addArrangedSubview(iconView)
        }

        var hasAddedCapability = false
        for (label, count, tag) in visibleItems {
            if hasAddedCapability || !agentInfoStack.arrangedSubviews.isEmpty {
                let dot = NSTextField(labelWithString: "\u{00B7}")
                dot.font = .systemFont(ofSize: 11, weight: .medium)
                dot.textColor = .tertiaryLabelColor
                agentInfoStack.addArrangedSubview(dot)
            }
            hasAddedCapability = true
            let btn = AgentInfoButton(title: "\(count) \(label)", tag: tag, target: self, action: #selector(agentInfoButtonClicked(_:)))
            agentInfoStack.addArrangedSubview(btn)
        }

        agentInfoStack.isHidden = false
    }

    @objc private func agentInfoButtonClicked(_ sender: NSButton) {
        guard let caps = currentCapabilities else { return }

        let category: AgentInfoCategory
        var startInDetail = false
        switch sender.tag {
        case 0: category = .mcps(caps.mcpServers)
        case 1:
            category = .skills(caps.skills)
            startInDetail = caps.skills.count == 1
        case 2: category = .plugins(caps.plugins.filter(\.enabled))
        case 3:
            category = .instructions(caps.instructions)
            startInDetail = caps.instructions.count == 1
        default: return
        }

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: AgentInfoPopoverView(
            category: category,
            startInDetail: startInDetail
        ))
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: - Menu Actions (Tabs)

    @objc func newTab(_: Any?) {
        let store = ProjectStore.shared
        let dir = store.effectivePath ?? NSHomeDirectory()
        sessionManager.createSession(
            workingDirectory: dir,
            projectID: store.activeProjectID,
            workspaceID: store.activeWorkspaceID
        )
    }

    @objc func closeTab(_: Any?) {
        guard let activeID = sessionManager.activeTabID else { return }
        sessionManager.closeTab(id: activeID)
    }

    @objc func switchToTab(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        sessionManager.activateTab(at: index)
    }

    @objc func previousTab(_: Any?) {
        guard let current = sessionManager.activeTabIndex(), current > 0 else { return }
        sessionManager.activateTab(at: current - 1)
    }

    @objc func nextTab(_: Any?) {
        guard let current = sessionManager.activeTabIndex(),
              current < sessionManager.visibleTabs.count - 1 else { return }
        sessionManager.activateTab(at: current + 1)
    }

    // MARK: - Menu Actions (Panes)

    @objc func splitVertical(_: Any?) {
        sessionManager.splitFocusedPane(axis: .vertical)
    }

    @objc func splitHorizontal(_: Any?) {
        sessionManager.splitFocusedPane(axis: .horizontal)
    }

    @objc func closePane(_: Any?) {
        sessionManager.closeFocusedPane()
    }

    @objc func focusNextPane(_: Any?) {
        sessionManager.focusNextPane()
    }

    @objc func focusPreviousPane(_: Any?) {
        sessionManager.focusPreviousPane()
    }

    // MARK: - Pane Layout Refresh

    @objc private func handlePaneLayoutChanged() {
        showActiveTab()
    }

    @objc private func handleAgentChanged() {
        sessionManager.refreshAgentTitles()
        updateTabBar()
        updateStatusBar()
    }
}

// MARK: - Agent Info Button (plain text, hover underline)

private class AgentInfoButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var buttonTag: Int
    private weak var buttonTarget: AnyObject?
    private var buttonAction: Selector?

    init(title: String, tag: Int, target: AnyObject, action: Selector) {
        buttonTag = tag
        buttonTarget = target
        buttonAction = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var tag: Int {
        get { buttonTag }
        set { buttonTag = newValue }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with _: NSEvent) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: attrs)
    }

    override func mouseExited(with _: NSEvent) {
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
    }

    override func mouseDown(with _: NSEvent) {
        _ = buttonTarget?.perform(buttonAction, with: self)
    }
}

/// NSView subclass that accepts first responder so the TerminalContainerViewController
/// is always in the responder chain for menu shortcuts (Cmd+T, Cmd+W, etc.).
private class FirstResponderView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }
}
