import Foundation

/// Tracks per-tab agent work and periodically emits activity log updates.
///
/// Uses a dirty-flag + timer model: agent events set a dirty flag, and a 5-minute
/// repeating timer checks whether to emit a diff-aware summary. The timer auto-stops
/// when the agent is idle, and restarts on next activity.
@MainActor
class AgentWorkTracker: ObservableObject {
    static let shared = AgentWorkTracker()

    private let checkInterval: TimeInterval = 300 // 5 minutes

    private struct TabSession {
        let workspaceID: UUID
        let agent: String
        var dirty: Bool = false
        var lastSummary: String?
        var timer: Timer?
        var checkInFlight: Bool = false
    }

    private var sessions: [UUID: TabSession] = [:]

    private init() {}

    // MARK: - Public API

    /// Mark a tab as having new agent activity. On first dirty (or after timer stopped),
    /// fires an immediate check and starts the 5-minute timer.
    func markDirty(tabID: UUID, agent: String) {
        if sessions[tabID] == nil {
            guard let wsID = TerminalSessionManager.shared.workspaceID(for: tabID) else { return }
            sessions[tabID] = TabSession(workspaceID: wsID, agent: agent)
        }

        sessions[tabID]?.dirty = true

        // If no timer running, this is first dirty or timer stopped from idle — fire immediately
        if sessions[tabID]?.timer == nil {
            performCheck(tabID: tabID)
            startTimer(for: tabID)
        }
    }

    /// Clean up when a tab is closed. Fires a final check if dirty.
    func clearForTab(_ tabID: UUID) {
        guard var session = sessions[tabID] else { return }
        session.timer?.invalidate()
        session.timer = nil
        sessions[tabID] = session

        if session.dirty {
            performCheck(tabID: tabID)
        }

        sessions.removeValue(forKey: tabID)
    }

    // MARK: - Timer

    private func startTimer(for tabID: UUID) {
        sessions[tabID]?.timer?.invalidate()
        sessions[tabID]?.timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.timerFired(tabID: tabID)
            }
        }
    }

    private func stopTimer(for tabID: UUID) {
        sessions[tabID]?.timer?.invalidate()
        sessions[tabID]?.timer = nil
    }

    private func timerFired(tabID: UUID) {
        guard let session = sessions[tabID] else { return }

        if session.dirty {
            performCheck(tabID: tabID)
        } else {
            // Not dirty — agent is idle, stop polling
            stopTimer(for: tabID)
        }
    }

    // MARK: - Check Logic

    private func performCheck(tabID: UUID) {
        guard var session = sessions[tabID], session.dirty, !session.checkInFlight else { return }

        session.dirty = false
        session.checkInFlight = true
        sessions[tabID] = session

        let wsID = session.workspaceID
        let agent = session.agent
        let previousSummary = session.lastSummary

        // Collect terminal scrollback
        let context = collectTabContext(tabID: tabID)
        guard !context.isEmpty else {
            sessions[tabID]?.checkInFlight = false
            return
        }

        // Resolve display name
        let agentName = AgentStore.shared.agents.first(where: { $0.command == agent })?.name ?? agent

        // Create pending event
        let event = ActivityEvent(
            kind: .agentUpdate,
            title: agentName,
            isPending: true
        )
        let eventID = event.id
        ActivityLogStore.shared.append(workspaceID: wsID, event: event)

        // Generate snapshot asynchronously
        Task.detached(priority: .utility) {
            let summary = await ActivitySnapshotCommand.run(context: context, previousSummary: previousSummary)

            await MainActor.run { [weak self] in
                guard let self else { return }
                sessions[tabID]?.checkInFlight = false

                // Session may have been cleared while we were generating
                guard sessions[tabID] != nil else {
                    ActivityLogStore.shared.removeEvent(workspaceID: wsID, eventID: eventID)
                    return
                }

                if let summary, summary != ActivitySnapshotCommand.unchangedSentinel {
                    ActivityLogStore.shared.updateEvent(workspaceID: wsID, eventID: eventID) { event in
                        event.detail = summary
                        event.isPending = false
                    }
                    sessions[tabID]?.lastSummary = summary
                } else {
                    // UNCHANGED or failure — remove the pending event
                    ActivityLogStore.shared.removeEvent(workspaceID: wsID, eventID: eventID)
                }
            }
        }
    }

    // MARK: - Terminal Context Collection

    private func collectTabContext(tabID: UUID) -> String {
        guard let tab = TerminalSessionManager.shared.tabs.first(where: { $0.id == tabID }),
              tab.kind.isTerminal else { return "" }

        let sessionIDs = tab.paneManager?.allSessionIDs ?? tab.sessionIDs
        var parts: [String] = []

        for sessionID in sessionIDs {
            guard let view = TerminalCache.shared.view(for: sessionID),
                  let scrollback = view.captureScrollback(lineLimit: 200) else { continue }

            let cleaned = Self.stripANSI(scrollback)
            guard !cleaned.isEmpty else { continue }
            parts.append(cleaned)
        }

        let joined = parts.joined(separator: "\n\n")
        if joined.count > 4000 {
            return String(joined.prefix(4000))
        }
        return joined
    }

    static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\x1b\\[[0-9;]*[a-zA-Z]") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
