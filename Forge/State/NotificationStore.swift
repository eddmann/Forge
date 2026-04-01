import AppKit
import UserNotifications

/// Manages terminal notifications and agent status.
/// Receives notifications from ForgeSocketServer via the forge CLI.
class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    // MARK: - Types

    struct TerminalNotification: Identifiable {
        let id: UUID
        let tabID: UUID
        let sessionID: UUID?
        let title: String
        let body: String
        let createdAt: Date
        var isRead: Bool
    }

    // MARK: - Published State

    /// Agent status per tab — driven by "status:running/waiting/idle" messages
    @Published private(set) var agentStatusByTab: [UUID: AgentStatus] = [:]

    /// Notifications (most recent first)
    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            rebuildUnreadCounts()
            refreshDockBadge()
        }
    }

    /// Unread notification count per tab
    @Published private(set) var unreadCountByTab: [UUID: Int] = [:]

    var totalUnreadCount: Int {
        unreadCountByTab.values.reduce(0, +)
    }

    // MARK: - Init

    private init() {
        requestAuthorization()
    }

    // MARK: - Socket Notifications

    /// Called from ForgeSocketServer when a notify command arrives via socket.
    /// Must be called on the main thread.
    func handleSocketNotification(sessionID: UUID?, title: String, body: String) {
        let tabID: UUID? = MainActor.assumeIsolated {
            TerminalSessionManager.shared.tabs.first(where: { tab in
                guard let sessionID else { return false }
                return tab.paneManager?.allSessionIDs.contains(sessionID) == true
                    || tab.sessionIDs.contains(sessionID)
            })?.id
        }

        guard let tabID else { return }
        handleNotification(tabID: tabID, sessionID: sessionID, title: title, body: body)
    }

    // MARK: - Incoming Notifications

    /// Parses the body to determine if it's a status update or a notification.
    func handleNotification(tabID: UUID, sessionID: UUID?, title: String, body: String) {
        // Status update: body starts with "status:"
        if body.hasPrefix("status:") {
            let status = String(body.dropFirst("status:".count))
            handleStatusUpdate(tabID: tabID, title: title, status: status)
            return
        }

        // Regular notification — clear running status since work is done
        let previousStatus = agentStatusByTab[tabID] ?? .idle
        agentStatusByTab[tabID] = .idle
        SummaryLog.log("[Summary] handleNotification: title='\(title)' body='\(body)' previousStatus=\(previousStatus) tabID=\(tabID)")
        addNotification(tabID: tabID, sessionID: sessionID, title: title, body: body)

        // Trigger workspace summarization on running → idle transition
        if previousStatus == .running {
            MainActor.assumeIsolated {
                if let wsID = TerminalSessionManager.shared.workspaceID(for: tabID) {
                    SummaryLog.log("[Summary] Triggering summarization for workspace \(wsID)")
                    SummaryScheduler.shared.workspaceActivityDetected(workspaceID: wsID)
                } else {
                    SummaryLog.log("[Summary] No workspaceID found for tab \(tabID)")
                }
            }
        } else {
            SummaryLog.log("[Summary] Skipped: previousStatus was \(previousStatus), not running")
        }
    }

    // MARK: - Status Updates

    private func handleStatusUpdate(tabID: UUID, title: String, status: String) {
        let previousStatus = agentStatusByTab[tabID] ?? .idle
        SummaryLog.log("[Summary] handleStatusUpdate: status='\(status)' previousStatus=\(previousStatus) tabID=\(tabID)")

        switch status {
        case "running":
            agentStatusByTab[tabID] = .running

        case "waiting":
            agentStatusByTab[tabID] = .waitingForInput
            // Also create a notification for waiting state
            addNotification(tabID: tabID, sessionID: nil, title: title, body: "Waiting for permission")

        case "idle":
            agentStatusByTab[tabID] = .idle
            // If transitioning from running → idle, create "Task complete" notification
            if previousStatus == .running {
                addNotification(tabID: tabID, sessionID: nil, title: title, body: "Task complete")

                // Trigger workspace summarization
                MainActor.assumeIsolated {
                    if let wsID = TerminalSessionManager.shared.workspaceID(for: tabID) {
                        SummaryScheduler.shared.workspaceActivityDetected(workspaceID: wsID)
                    }
                }
            }

        default:
            break
        }
    }

    // MARK: - Notifications

    func addNotification(tabID: UUID, sessionID: UUID?, title: String, body: String) {
        var updated = notifications
        // Deduplicate: remove previous unread notification for same tab/session
        updated.removeAll { $0.tabID == tabID && $0.sessionID == sessionID && !$0.isRead }

        let notification = TerminalNotification(
            id: UUID(),
            tabID: tabID,
            sessionID: sessionID,
            title: title.isEmpty ? "Terminal" : title,
            body: body,
            createdAt: Date(),
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated

        // Delivery: suppress banner if user is looking at this tab
        let isActiveTab = MainActor.assumeIsolated { TerminalSessionManager.shared.activeTabID } == tabID
        let isAppFocused = NSApp.isActive

        if isAppFocused, isActiveTab {
            NSSound.beep()
        } else {
            deliverSystemNotification(notification)
        }
    }

    // MARK: - Read/Unread

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

    func remove(id: UUID) {
        notifications.removeAll { $0.id == id }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func clearForTab(_ tabID: UUID) {
        let ids = notifications.filter { $0.tabID == tabID }.map(\.id.uuidString)
        notifications.removeAll { $0.tabID == tabID }
        agentStatusByTab.removeValue(forKey: tabID)
        if !ids.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: - Queries

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

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func deliverSystemNotification(_ notification: TerminalNotification) {
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
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
