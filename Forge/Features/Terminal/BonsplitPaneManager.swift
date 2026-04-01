import Foundation

/// Manages a BonsplitController for a single workspace tab.
/// Maps between Bonsplit's TabID/PaneID and Forge's session UUIDs.
@MainActor
class BonsplitPaneManager: NSObject, BonsplitDelegate {
    let controller: BonsplitController

    /// Session UUID → Bonsplit TabID
    private var sessionToTabID: [UUID: TabID] = [:]
    /// Bonsplit TabID → Session UUID
    private var tabIDToSession: [TabID: UUID] = [:]

    /// Called when a pane's terminal process exits and needs cleanup.
    var onSessionClosed: ((UUID) -> Void)?

    /// The workspace tab ID this manager belongs to (for session scoping).
    let workspaceTabID: UUID
    var projectID: UUID?
    var workspaceID: UUID?

    init(workspaceTabID: UUID, projectID: UUID? = nil, workspaceID: UUID? = nil) {
        self.workspaceTabID = workspaceTabID
        self.projectID = projectID
        self.workspaceID = workspaceID

        var config = BonsplitConfiguration()
        config.allowSplits = true
        config.allowCloseLastPane = false
        config.allowCloseTabs = true
        config.allowTabReordering = false // One terminal per pane, no reordering
        config.allowCrossPaneTabMove = false // No dragging tabs between panes
        config.autoCloseEmptyPanes = true
        config.contentViewLifecycle = .keepAllAlive
        config.appearance.tabBarHeight = 0 // Hide Bonsplit's per-pane tab bar — Forge has its own
        config.appearance.showSplitButtons = false
        config.appearance.enableAnimations = true
        config.appearance.minimumPaneWidth = 80
        config.appearance.minimumPaneHeight = 60

        controller = BonsplitController(configuration: config)
        super.init()
        controller.delegate = self
    }

    // MARK: - Session Management

    /// Add a terminal session to this split layout.
    @discardableResult
    func addSession(_ session: TerminalSession) -> TabID {
        let tabID = controller.createTab(
            title: session.title,
            icon: nil,
            kind: "terminal"
        ) ?? TabID()

        sessionToTabID[session.id] = tabID
        tabIDToSession[tabID] = session.id
        return tabID
    }

    /// Remove a session from the split layout.
    /// Bonsplit closes the tab and auto-closes the empty pane.
    /// Cleanup happens in the didCloseTab delegate callback.
    func removeSession(_ sessionID: UUID) {
        guard let tabID = sessionToTabID[sessionID] else { return }
        controller.closeTab(tabID)
        // Don't remove from mappings here — let didCloseTab delegate handle it
    }

    /// Look up session UUID from a Bonsplit TabID.
    func sessionID(for tabID: TabID) -> UUID? {
        tabIDToSession[tabID]
    }

    /// The currently focused session.
    var focusedSessionID: UUID? {
        guard let paneID = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: paneID) else { return nil }
        return tabIDToSession[tab.id]
    }

    /// All session IDs in this split layout.
    var allSessionIDs: [UUID] {
        Array(sessionToTabID.keys)
    }

    /// Number of panes in the split layout.
    var paneCount: Int {
        controller.allPaneIds.count
    }

    // MARK: - Split Operations

    /// Split the focused pane. Creates a new session and returns its ID.
    @discardableResult
    func split(orientation: SplitOrientation, workingDirectory: String) -> UUID? {
        let newSession = TerminalSession(title: "Shell", workingDirectory: workingDirectory)
        TerminalSessionManager.shared.addSession(newSession)

        let tab = Tab(
            id: TabID(),
            title: newSession.title,
            kind: "terminal"
        )

        let newPaneID = controller.splitPane(
            orientation: orientation,
            withTab: tab
        )

        guard newPaneID != nil else {
            TerminalSessionManager.shared.removeSession(newSession.id)
            return nil
        }

        sessionToTabID[newSession.id] = tab.id
        tabIDToSession[tab.id] = newSession.id

        return newSession.id
    }

    /// Close the focused pane.
    func closeFocusedPane() {
        guard let paneID = controller.focusedPaneId else { return }
        // Get session before closing so we can clean it up
        if let tab = controller.selectedTab(inPane: paneID),
           let sessionID = tabIDToSession[tab.id]
        {
            controller.closePane(paneID)
            // Cleanup happens in didCloseTab delegate
        }
    }

    /// Navigate focus in a direction.
    func navigateFocus(direction: NavigationDirection) {
        controller.navigateFocus(direction: direction)
    }

    // MARK: - Layout Snapshot

    /// Capture the split layout tree with session UUIDs replacing Bonsplit TabIDs.
    func splitLayoutSnapshot() -> SplitLayoutSnapshot? {
        let tree = controller.treeSnapshot()
        return convertToLayoutSnapshot(tree)
    }

    private func convertToLayoutSnapshot(_ node: ExternalTreeNode) -> SplitLayoutSnapshot? {
        switch node {
        case let .pane(paneNode):
            // Find the session UUID for this pane's tab
            guard let tabIDString = paneNode.tabs.first?.id,
                  let tabUUID = UUID(uuidString: tabIDString),
                  let sessionID = tabIDToSession[TabID(uuid: tabUUID)]
            else {
                return nil
            }
            return .pane(SplitLayoutSnapshot.SplitLayoutPane(session: sessionID.uuidString))

        case let .split(splitNode):
            guard let first = convertToLayoutSnapshot(splitNode.first),
                  let second = convertToLayoutSnapshot(splitNode.second)
            else {
                return nil
            }
            return .split(SplitLayoutSnapshot.SplitLayoutSplit(
                orientation: splitNode.orientation,
                dividerPosition: splitNode.dividerPosition,
                first: first,
                second: second
            ))
        }
    }

    /// Restore splits from a saved layout snapshot.
    /// Returns the mapping of split IDs to divider positions for deferred application.
    func restoreFromLayoutSnapshot(_ layout: SplitLayoutSnapshot) -> [(UUID, Double)] {
        var dividerPositions: [(UUID, Double)] = []
        restoreNode(layout, dividerPositions: &dividerPositions)
        return dividerPositions
    }

    private func restoreNode(_ node: SplitLayoutSnapshot, dividerPositions: inout [(UUID, Double)]) {
        guard case let .split(split) = node else { return }

        let orientation: SplitOrientation = split.orientation == "horizontal" ? .horizontal : .vertical

        // Collect session IDs from the second branch (these need to be split off)
        let secondSessionIDs = collectSessionIDs(from: split.second)
        guard let firstSessionToSplit = secondSessionIDs.first,
              let firstSessionUUID = UUID(uuidString: firstSessionToSplit) else { return }

        // The second branch's first session gets split off from whatever is focused
        if let tabID = sessionToTabID[firstSessionUUID] {
            let tab = Tab(id: tabID, title: "Shell", kind: "terminal")
            if let newPaneID = controller.splitPane(orientation: orientation, withTab: tab) {
                // Record divider position to apply after all splits are done
                // The split ID is from the tree structure
                let tree = controller.treeSnapshot()
                if let splitID = findLastSplitID(in: tree) {
                    dividerPositions.append((splitID, split.dividerPosition))
                }
            }
        }

        // Recurse into sub-splits
        restoreNode(split.first, dividerPositions: &dividerPositions)
        restoreNode(split.second, dividerPositions: &dividerPositions)
    }

    private func collectSessionIDs(from node: SplitLayoutSnapshot) -> [String] {
        switch node {
        case let .pane(pane):
            [pane.session]
        case let .split(split):
            collectSessionIDs(from: split.first) + collectSessionIDs(from: split.second)
        }
    }

    private func findLastSplitID(in node: ExternalTreeNode) -> UUID? {
        switch node {
        case .pane:
            nil
        case let .split(split):
            // Return the deepest split, or this one
            findLastSplitID(in: split.second)
                ?? findLastSplitID(in: split.first)
                ?? UUID(uuidString: split.id)
        }
    }

    // MARK: - BonsplitDelegate

    func splitTabBar(_: BonsplitController, didCloseTab tabId: TabID, fromPane _: PaneID) {
        guard let sessionID = tabIDToSession[tabId] else { return }
        tabIDToSession.removeValue(forKey: tabId)
        sessionToTabID.removeValue(forKey: sessionID)
        onSessionClosed?(sessionID)
    }

    func splitTabBar(_: BonsplitController, didFocusPane _: PaneID) {
        if let sessionID = focusedSessionID {
            TerminalSessionManager.shared.setFocusedSession(sessionID)
        }
    }

    func splitTabBar(_: BonsplitController, didSplitPane _: PaneID, newPane _: PaneID, orientation _: SplitOrientation) {
        // Split already handled in split() method
    }

    func splitTabBar(_: BonsplitController, didRequestNewTab _: String, inPane _: PaneID) {
        // Could create a new terminal in this pane in future
    }
}
