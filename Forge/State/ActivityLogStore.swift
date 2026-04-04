import Foundation

/// Manages per-workspace activity logs — persistent timeline of workspace events.
@MainActor
class ActivityLogStore: ObservableObject {
    static let shared = ActivityLogStore()

    @Published private(set) var eventsByWorkspace: [UUID: [ActivityEvent]] = [:]

    /// Per-tab cooldown tracking for snapshot generation (5 minutes).
    private var lastSnapshotTime: [UUID: Date] = [:]
    private let snapshotCooldown: TimeInterval = 300

    /// Debounced persistence.
    private var saveTimers: [UUID: DispatchWorkItem] = [:]
    private let saveDebounce: TimeInterval = 2.0

    private let activityDir: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        activityDir = ForgeStore.shared.stateDir.appendingPathComponent("activity")
        try? FileManager.default.createDirectory(at: activityDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func append(workspaceID: UUID, event: ActivityEvent) {
        ensureLoaded(workspaceID: workspaceID)
        eventsByWorkspace[workspaceID, default: []].append(event)
        scheduleSave(workspaceID: workspaceID)
    }

    func events(for workspaceID: UUID) -> [ActivityEvent] {
        ensureLoaded(workspaceID: workspaceID)
        return eventsByWorkspace[workspaceID] ?? []
    }

    func clearLog(workspaceID: UUID) {
        eventsByWorkspace.removeValue(forKey: workspaceID)
        loadedWorkspaces.remove(workspaceID)
        try? FileManager.default.removeItem(at: fileURL(for: workspaceID))
    }

    func saveImmediately() {
        for (workspaceID, _) in eventsByWorkspace {
            saveTimers[workspaceID]?.cancel()
            saveTimers.removeValue(forKey: workspaceID)
            saveToDisk(workspaceID: workspaceID)
        }
    }

    // MARK: - Snapshots

    func requestSnapshot(workspaceID: UUID, tabID: UUID, agent: String, tense: ActivitySnapshotCommand.Tense) {
        // Skip cooldown for past-tense (stop) snapshots — always capture the final summary
        if tense == .present {
            if let lastTime = lastSnapshotTime[tabID],
               Date().timeIntervalSince(lastTime) < snapshotCooldown
            {
                return
            }
        }

        lastSnapshotTime[tabID] = Date()

        // Collect single-tab scrollback
        guard let tab = TerminalSessionManager.shared.tabs.first(where: { $0.id == tabID }),
              tab.kind.isTerminal else { return }

        let context = collectTabContext(tab)
        guard !context.isEmpty else { return }

        // Create pending event
        let agentName = AgentStore.shared.agents.first(where: { $0.command == agent })?.name ?? agent
        let event = ActivityEvent(
            kind: .agentSnapshot,
            title: "\(agentName) update",
            isPending: true
        )
        let eventID = event.id
        append(workspaceID: workspaceID, event: event)

        // Generate snapshot asynchronously
        Task.detached(priority: .utility) {
            let summary = await ActivitySnapshotCommand.run(context: context, tense: tense)

            await MainActor.run {
                if let summary {
                    self.updateEvent(workspaceID: workspaceID, eventID: eventID) { event in
                        event.detail = summary
                        event.isPending = false
                    }
                } else {
                    // Snapshot generation failed — remove the pending event
                    self.removeEvent(workspaceID: workspaceID, eventID: eventID)
                }
            }
        }
    }

    // MARK: - Private

    private var loadedWorkspaces: Set<UUID> = []

    private func ensureLoaded(workspaceID: UUID) {
        guard !loadedWorkspaces.contains(workspaceID) else { return }
        loadedWorkspaces.insert(workspaceID)
        let url = fileURL(for: workspaceID)
        if let data = try? Data(contentsOf: url),
           let events = try? decoder.decode([ActivityEvent].self, from: data)
        {
            eventsByWorkspace[workspaceID] = events
        }
    }

    private func removeEvent(workspaceID: UUID, eventID: UUID) {
        guard var events = eventsByWorkspace[workspaceID] else { return }
        events.removeAll { $0.id == eventID }
        eventsByWorkspace[workspaceID] = events
        scheduleSave(workspaceID: workspaceID)
    }

    private func updateEvent(workspaceID: UUID, eventID: UUID, update: (inout ActivityEvent) -> Void) {
        guard var events = eventsByWorkspace[workspaceID],
              let index = events.firstIndex(where: { $0.id == eventID })
        else { return }
        update(&events[index])
        eventsByWorkspace[workspaceID] = events
        scheduleSave(workspaceID: workspaceID)
    }

    private func collectTabContext(_ tab: TerminalTab) -> String {
        let sessionIDs = tab.paneManager?.allSessionIDs ?? tab.sessionIDs
        var parts: [String] = []

        for sessionID in sessionIDs {
            guard let view = TerminalCache.shared.view(for: sessionID),
                  let scrollback = view.captureScrollback(lineLimit: 200) else { continue }

            let cleaned = stripANSI(scrollback)
            guard !cleaned.isEmpty else { continue }
            parts.append(cleaned)
        }

        let joined = parts.joined(separator: "\n\n")
        // Cap at 4000 chars
        if joined.count > 4000 {
            return String(joined.prefix(4000))
        }
        return joined
    }

    private func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\x1b\\[[0-9;]*[a-zA-Z]") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Persistence

    private func fileURL(for workspaceID: UUID) -> URL {
        activityDir.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    private func scheduleSave(workspaceID: UUID) {
        saveTimers[workspaceID]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveToDisk(workspaceID: workspaceID)
        }
        saveTimers[workspaceID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounce, execute: item)
    }

    private func saveToDisk(workspaceID: UUID) {
        guard let events = eventsByWorkspace[workspaceID] else { return }
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: fileURL(for: workspaceID), options: .atomic)
    }
}
