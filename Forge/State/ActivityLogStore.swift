import Foundation

/// Manages per-workspace activity logs — persistent timeline of workspace events.
@MainActor
class ActivityLogStore: ObservableObject {
    static let shared = ActivityLogStore()

    @Published private(set) var eventsByWorkspace: [UUID: [ActivityEvent]] = [:]

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

    // MARK: - Event Mutation (used by AgentWorkTracker)

    func removeEvent(workspaceID: UUID, eventID: UUID) {
        guard var events = eventsByWorkspace[workspaceID] else { return }
        events.removeAll { $0.id == eventID }
        eventsByWorkspace[workspaceID] = events
        scheduleSave(workspaceID: workspaceID)
    }

    func updateEvent(workspaceID: UUID, eventID: UUID, update: (inout ActivityEvent) -> Void) {
        guard var events = eventsByWorkspace[workspaceID],
              let index = events.firstIndex(where: { $0.id == eventID })
        else { return }
        update(&events[index])
        eventsByWorkspace[workspaceID] = events
        scheduleSave(workspaceID: workspaceID)
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
