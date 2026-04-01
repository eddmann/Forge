import AppKit
import Combine
import UserNotifications

/// Unified store for agent events — receives from socket and terminal observer, drives UI.
@MainActor
class AgentEventStore: ObservableObject {
    static let shared = AgentEventStore()

    // MARK: - Published State

    /// Agent activity per tab
    @Published var activityByTab: [UUID: AgentActivity] = [:]

    /// Full agent state per tab (for detail views)
    @Published private(set) var stateByTab: [UUID: AgentSessionState] = [:]

    /// Unread notification count per tab
    @Published private(set) var unreadCountByTab: [UUID: Int] = [:]

    var totalUnreadCount: Int {
        unreadCountByTab.values.reduce(0, +)
    }

    // MARK: - Notifications

    struct AgentNotification: Identifiable {
        let id: UUID
        let tabID: UUID
        let sessionID: UUID?
        let title: String
        let body: String
        let createdAt: Date
        var isRead: Bool
    }

    @Published private(set) var notifications: [AgentNotification] = [] {
        didSet {
            rebuildUnreadCounts()
            refreshDockBadge()
        }
    }

    private init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Agent Events (from socket)

    func handleAgentEvent(sessionID: UUID?, agent: String, event: String, data: [String: Any]) {
        AgentEventLogger.shared.log(source: "socket", session: sessionID, agent: agent, event: event, data: data)

        guard let tabID = resolveTabID(sessionID: sessionID) else { return }

        // Initialize state if needed
        if stateByTab[tabID] == nil {
            stateByTab[tabID] = AgentSessionState(agent: agent)
        }

        switch event {
        case "session_start":
            stateByTab[tabID]?.agentSessionID = data["session_id"] as? String
            stateByTab[tabID]?.transcriptPath = data["transcript_path"] as? String
            stateByTab[tabID]?.cwd = data["cwd"] as? String
            stateByTab[tabID]?.model = data["model"] as? String
            // Don't set activity here — session_start fires on agent launch, not on work start.
            // Let prompt/tool_start/terminal signals set the actual activity.

        case "prompt":
            stateByTab[tabID]?.lastPrompt = data["prompt"] as? String
            activityByTab[tabID] = .thinking

        case "tool_start":
            let toolName = data["tool_name"] as? String ?? "Unknown"
            stateByTab[tabID]?.currentTool = ToolExecution(
                name: toolName,
                input: data["tool_input"] as? [String: Any],
                startedAt: Date()
            )
            activityByTab[tabID] = .toolExecuting

        case "tool_end":
            stateByTab[tabID]?.currentTool = nil
            // Back to thinking — the agent is processing the tool result
            activityByTab[tabID] = .thinking

        case "stop":
            stateByTab[tabID]?.lastResponse = data["last_assistant_message"] as? String
            stateByTab[tabID]?.currentTool = nil
            let previousActivity = activityByTab[tabID]
            activityByTab[tabID] = .idle

            // Task complete notification — auto-read on active tab
            let agentName = AgentStore.shared.agents.first(where: { $0.command == agent })?.name ?? agent
            addNotification(tabID: tabID, sessionID: sessionID, title: agentName, body: "Task complete")
            if TerminalSessionManager.shared.activeTabID == tabID {
                markRead(tabID: tabID)
            }

            // Trigger summarization on working → idle
            if previousActivity == .thinking || previousActivity == .toolExecuting {
                if let wsID = TerminalSessionManager.shared.workspaceID(for: tabID) {
                    SummaryScheduler.shared.workspaceActivityDetected(workspaceID: wsID)
                }
            }

        case "notification":
            let message = data["message"] as? String ?? ""
            let title = data["title"] as? String ?? agent
            stateByTab[tabID]?.permissionDetail = message
            activityByTab[tabID] = .waitingForPermission
            addNotification(tabID: tabID, sessionID: sessionID, title: title, body: message)

        case "agent_start":
            activityByTab[tabID] = .thinking

        case "turn_start":
            activityByTab[tabID] = .thinking

        case "turn_end":
            // Turn finished but agent may continue — set idle
            stateByTab[tabID]?.currentTool = nil
            activityByTab[tabID] = .idle

        case "message_start":
            activityByTab[tabID] = .thinking

        case "message_end":
            break // No state change — wait for turn_end or stop

        case "compaction_start":
            activityByTab[tabID] = .compacting

        case "compaction_end":
            activityByTab[tabID] = .thinking

        case "retry_start":
            activityByTab[tabID] = .retrying

        case "status":
            // OpenCode direct status events
            if let status = data["status"] as? String {
                switch status {
                case "busy": activityByTab[tabID] = .thinking
                case "retry": activityByTab[tabID] = .retrying
                case "idle":
                    let previousActivity = activityByTab[tabID]
                    activityByTab[tabID] = .idle
                    if previousActivity == .thinking || previousActivity == .toolExecuting {
                        let agentName = AgentStore.shared.agents.first(where: { $0.command == agent })?.name ?? agent
                        addNotification(tabID: tabID, sessionID: sessionID, title: agentName, body: "Task complete")
                        if TerminalSessionManager.shared.activeTabID == tabID {
                            markRead(tabID: tabID)
                        }
                        if let wsID = TerminalSessionManager.shared.workspaceID(for: tabID) {
                            SummaryScheduler.shared.workspaceActivityDetected(workspaceID: wsID)
                        }
                    }
                default: break
                }
            }

        case "permission":
            stateByTab[tabID]?.permissionDetail = data["permission"] as? String
            activityByTab[tabID] = .waitingForPermission

        default:
            break
        }
    }

    // MARK: - Session Resolution

    private func resolveTabID(sessionID: UUID?) -> UUID? {
        guard let sessionID else { return nil }
        return TerminalSessionManager.shared.tabs.first(where: { tab in
            tab.paneManager?.allSessionIDs.contains(sessionID) == true
                || tab.sessionIDs.contains(sessionID)
        })?.id
    }

    // MARK: - Terminal Signals (from TerminalObserver)

    func updateFromTerminalSignals(tabID: UUID, agent: String?, activity: AgentActivity) {
        guard let agent else {
            if activityByTab.removeValue(forKey: tabID) != nil {}
            return
        }
        // Only publish if activity actually changed — prevents rapid title updates
        // (e.g. Codex spinner at 100ms) from rebuilding the tab bar and killing animations
        let previousActivity = activityByTab[tabID]
        guard previousActivity != activity else { return }
        activityByTab[tabID] = activity

        // Detect working → idle transition from terminal signals alone.
        // This catches agents whose Stop hook may not fire (e.g. Codex)
        // or when the terminal title reverts before the hook arrives.
        if activity == .idle,
           previousActivity == .thinking || previousActivity == .toolExecuting
        {
            let agentName = AgentStore.shared.agents.first(where: { $0.command == agent })?.name ?? agent
            addNotification(tabID: tabID, sessionID: nil, title: agentName, body: "Task complete")
            if TerminalSessionManager.shared.activeTabID == tabID {
                markRead(tabID: tabID)
            }
            if let wsID = TerminalSessionManager.shared.workspaceID(for: tabID) {
                SummaryScheduler.shared.workspaceActivityDetected(workspaceID: wsID)
            }
        }
    }

    // MARK: - Notifications

    func addNotification(tabID: UUID, sessionID: UUID?, title: String, body: String) {
        let isActiveTab = TerminalSessionManager.shared.activeTabID == tabID
        let isAppFocused = NSApp.isActive

        var updated = notifications
        updated.removeAll { $0.tabID == tabID && $0.sessionID == sessionID && !$0.isRead }

        let notification = AgentNotification(
            id: UUID(), tabID: tabID, sessionID: sessionID,
            title: title.isEmpty ? "Terminal" : title,
            body: body, createdAt: Date(),
            isRead: isAppFocused && isActiveTab // Auto-read if user is looking at this tab
        )
        updated.insert(notification, at: 0)
        notifications = updated

        if isAppFocused, isActiveTab {
            NSSound.beep()
        } else {
            deliverSystemNotification(notification)
        }
    }

    func markRead(tabID: UUID) {
        var updated = notifications
        var changed = false
        for i in updated.indices {
            if updated[i].tabID == tabID, !updated[i].isRead {
                updated[i].isRead = true
                changed = true
            }
        }
        if changed {
            notifications = updated
            let ids = updated.filter { $0.tabID == tabID }.map(\.id.uuidString)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func markAllRead() {
        var updated = notifications
        for i in updated.indices {
            updated[i].isRead = true
        }
        notifications = updated
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func clearForTab(_ tabID: UUID) {
        let ids = notifications.filter { $0.tabID == tabID }.map(\.id.uuidString)
        notifications.removeAll { $0.tabID == tabID }
        activityByTab.removeValue(forKey: tabID)
        stateByTab.removeValue(forKey: tabID)
        if !ids.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func hasUnread(tabID: UUID) -> Bool {
        (unreadCountByTab[tabID] ?? 0) > 0
    }

    // MARK: - Private

    private func rebuildUnreadCounts() {
        var counts: [UUID: Int] = [:]
        for n in notifications where !n.isRead {
            counts[n.tabID, default: 0] += 1
        }
        unreadCountByTab = counts
    }

    private func refreshDockBadge() {
        let count = totalUnreadCount
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    #if DEBUG
        func setDemoState(tabID: UUID, state: AgentSessionState) {
            stateByTab[tabID] = state
        }

        func setDemoUnread(tabID: UUID, count: Int) {
            unreadCountByTab[tabID] = count
        }
    #endif

    private func deliverSystemNotification(_ notification: AgentNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = [
            "tabID": notification.tabID.uuidString,
            "notificationID": notification.id.uuidString
        ]
        let request = UNNotificationRequest(
            identifier: notification.id.uuidString,
            content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
