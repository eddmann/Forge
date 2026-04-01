import Foundation

/// Manages port allocation for OpenCode's auto-started HTTP server.
/// Each workspace gets a deterministic port from a range so Forge can connect via SSE.
class OpenCodePortManager {
    static let shared = OpenCodePortManager()

    /// Port range for OpenCode servers (avoids common ports)
    private let basePort = 13100
    private let portRange = 100

    /// Maps workspace/session to allocated port
    private var portBySession: [UUID: Int] = [:]
    private var nextOffset = 0

    private init() {}

    /// Get a deterministic port for a session. Allocates one if not yet assigned.
    func portForSession(sessionID: UUID?) -> Int {
        guard let sessionID else { return basePort }
        if let existing = portBySession[sessionID] {
            return existing
        }
        let port = basePort + (nextOffset % portRange)
        nextOffset += 1
        portBySession[sessionID] = port
        return port
    }

    /// Get the port for a tab's primary session
    @MainActor
    func portForTab(_ tabID: UUID) -> Int? {
        guard let tab = TerminalSessionManager.shared.tabs.first(where: { $0.id == tabID }) else { return nil }
        let sessionID = tab.paneManager?.allSessionIDs.first ?? tab.sessionIDs.first
        guard let sessionID else { return nil }
        return portBySession[sessionID]
    }
}
