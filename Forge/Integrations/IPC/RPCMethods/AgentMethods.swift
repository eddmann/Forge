import Foundation

// MARK: - agent.event

/// Forward an agent hook event. Installed agent hook scripts (Claude Code,
/// Codex) shell out to `forge agent event <agent> <event>` which routes
/// through here.
///
/// Params: `{agent: string, event: string, session_id?: string, data?: object}`
@MainActor
enum AgentEvent: ForgeRPCMethod {
    static let name = "agent.event"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        guard let agent = params["agent"] as? String else {
            throw ForgeRPCError.invalidParams("'agent' is required")
        }
        guard let event = params["event"] as? String else {
            throw ForgeRPCError.invalidParams("'event' is required")
        }
        let sessionID = (params["session_id"] as? String).flatMap(UUID.init(uuidString:))
        let data = params["data"] as? [String: Any] ?? [:]

        AgentEventStore.shared.handleAgentEvent(
            sessionID: sessionID,
            agent: agent,
            event: event,
            data: data
        )
        return ["ok": true]
    }
}
