import Foundation

// MARK: - agent.event

/// Forward an agent hook event, equivalent to `forge event <agent> <event>`
/// under the legacy protocol. Used by hooks installed in agent config files.
///
/// Params: `{agent: string, event: string, session_id?: string, data?: object}`
@MainActor
enum AgentEvent: ForgeRPCMethod {
    static let name = "agent.event"

    static func handle(params: [String: Any]) throws -> [String: Any] {
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

// MARK: - agent.set_status

/// Push an arbitrary status string onto the session, visible in the tab/inspector.
///
/// Params: `{session_id: string, agent?: string, text: string}`
/// `agent` is used only when initialising a fresh session state; it's typically
/// inferred from prior events.
@MainActor
enum AgentSetStatus: ForgeRPCMethod {
    static let name = "agent.set_status"

    static func handle(params: [String: Any]) throws -> [String: Any] {
        guard let sid = (params["session_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ForgeRPCError.invalidParams("'session_id' is required")
        }
        guard let text = params["text"] as? String else {
            throw ForgeRPCError.invalidParams("'text' is required")
        }
        let agent = (params["agent"] as? String) ?? "unknown"
        AgentEventStore.shared.setPushedStatus(sessionID: sid, agent: agent, text: text)
        return ["ok": true]
    }
}

// MARK: - agent.clear_status

@MainActor
enum AgentClearStatus: ForgeRPCMethod {
    static let name = "agent.clear_status"

    static func handle(params: [String: Any]) throws -> [String: Any] {
        guard let sid = (params["session_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ForgeRPCError.invalidParams("'session_id' is required")
        }
        AgentEventStore.shared.setPushedStatus(sessionID: sid, agent: "unknown", text: nil)
        return ["ok": true]
    }
}

// MARK: - agent.set_progress

/// Push a 0–100 progress value. Values outside [0, 100] are clamped.
///
/// Params: `{session_id: string, agent?: string, percent: int}`
@MainActor
enum AgentSetProgress: ForgeRPCMethod {
    static let name = "agent.set_progress"

    static func handle(params: [String: Any]) throws -> [String: Any] {
        guard let sid = (params["session_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ForgeRPCError.invalidParams("'session_id' is required")
        }
        guard let percent = params["percent"] as? Int else {
            throw ForgeRPCError.invalidParams("'percent' is required (int 0–100)")
        }
        let agent = (params["agent"] as? String) ?? "unknown"
        AgentEventStore.shared.setPushedProgress(sessionID: sid, agent: agent, percent: percent)
        return ["ok": true]
    }
}

// MARK: - agent.clear_progress

@MainActor
enum AgentClearProgress: ForgeRPCMethod {
    static let name = "agent.clear_progress"

    static func handle(params: [String: Any]) throws -> [String: Any] {
        guard let sid = (params["session_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ForgeRPCError.invalidParams("'session_id' is required")
        }
        AgentEventStore.shared.setPushedProgress(sessionID: sid, agent: "unknown", percent: nil)
        return ["ok": true]
    }
}
