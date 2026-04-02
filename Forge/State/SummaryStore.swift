import Foundation

/// Holds per-workspace activity summaries displayed in the sidebar.
class SummaryStore: ObservableObject {
    static let shared = SummaryStore()

    /// One-line summary per workspace UUID.
    @Published private(set) var summaryByWorkspace: [UUID: String] = [:]

    /// Workspaces currently being summarized.
    private var inFlight: Set<UUID> = []

    private init() {
        loadFromDisk()
    }

    func updateSummary(workspaceID: UUID, summary: String) {
        summaryByWorkspace[workspaceID] = summary
        inFlight.remove(workspaceID)
        saveToDisk()
    }

    func clearSummary(workspaceID: UUID) {
        summaryByWorkspace.removeValue(forKey: workspaceID)
        saveToDisk()
    }

    func isInFlight(_ workspaceID: UUID) -> Bool {
        inFlight.contains(workspaceID)
    }

    func markInFlight(_ workspaceID: UUID) {
        inFlight.insert(workspaceID)
    }

    func clearInFlight(_ workspaceID: UUID) {
        inFlight.remove(workspaceID)
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let stringKeyed = Dictionary(
            uniqueKeysWithValues: summaryByWorkspace.map { ($0.key.uuidString, $0.value) }
        )
        ForgeStore.shared.updateStateFields { state in
            state.summaries = stringKeyed
        }
    }

    private func loadFromDisk() {
        let state = ForgeStore.shared.loadStateFields()
        for (key, value) in state.summaries {
            if let uuid = UUID(uuidString: key) {
                summaryByWorkspace[uuid] = value
            }
        }
    }

    #if DEBUG
        func setDemo(workspaceID: UUID, summary: String) {
            summaryByWorkspace[workspaceID] = summary
        }
    #endif
}
