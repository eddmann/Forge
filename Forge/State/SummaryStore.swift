import Foundation

/// Holds per-workspace activity summaries displayed in the sidebar.
class SummaryStore: ObservableObject {
    static let shared = SummaryStore()

    /// One-line summary per workspace UUID.
    @Published private(set) var summaryByWorkspace: [UUID: String] = [:]

    /// Workspaces currently being summarized.
    private var inFlight: Set<UUID> = []

    private init() {}

    func updateSummary(workspaceID: UUID, summary: String) {
        summaryByWorkspace[workspaceID] = summary
        inFlight.remove(workspaceID)
    }

    func clearSummary(workspaceID: UUID) {
        summaryByWorkspace.removeValue(forKey: workspaceID)
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
}
