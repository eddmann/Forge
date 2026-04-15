import AppKit
import Foundation

// MARK: - terminal.list

/// List sessions, optionally filtered by workspace. Includes agent activity and
/// tab grouping so clients can build an overview.
@MainActor
enum TerminalList: ForgeRPCMethod {
    static let name = "terminal.list"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        let filterWorkspace = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
        var out: [[String: Any]] = []
        for tab in TerminalSessionManager.shared.tabs {
            if let filterWorkspace, tab.workspaceID != filterWorkspace { continue }
            let sessionIDs = tab.paneManager.map { Array($0.allSessionIDs) } ?? tab.sessionIDs
            let activity = AgentEventStore.shared.activityByTab[tab.id]?.rawValue
            let state = AgentEventStore.shared.stateByTab[tab.id]
            for sid in sessionIDs {
                guard let session = TerminalSessionManager.shared.session(for: sid) else { continue }
                var dict: [String: Any] = [
                    "id": session.id.uuidString,
                    "tab_id": tab.id.uuidString,
                    "title": session.title ?? NSNull(),
                    "working_directory": session.workingDirectory,
                    "agent": state?.agent ?? NSNull(),
                    "activity": activity ?? NSNull()
                ]
                dict["workspace_id"] = tab.workspaceID?.uuidString ?? NSNull()
                out.append(dict)
            }
        }
        return ["sessions": out]
    }
}

// MARK: - terminal.read_screen

/// Capture scrollback from a session as plain text. Wraps
/// `GhosttyTerminalView.captureScrollback`.
///
/// Params: `{session_id: string, lines?: int}`
@MainActor
enum TerminalReadScreen: ForgeRPCMethod {
    static let name = "terminal.read_screen"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = (params["session_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ForgeRPCError.invalidParams("'session_id' is required")
        }
        try requireScope(sessionID: sid, params: params)
        guard let view = TerminalCache.shared.view(for: sid) else {
            throw ForgeRPCError.notFound("No terminal for session \(sid.uuidString)")
        }
        let lines = (params["lines"] as? Int) ?? 4000
        let text = view.captureScrollback(lineLimit: lines) ?? ""
        return ["text": text]
    }
}

// MARK: - terminal.send_text

/// Type text into a session as if the user had entered it. Does not press
/// Return unless the text itself contains a newline.
///
/// Params: `{session_id: string, text: string}`
@MainActor
enum TerminalSendText: ForgeRPCMethod {
    static let name = "terminal.send_text"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = (params["session_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ForgeRPCError.invalidParams("'session_id' is required")
        }
        guard let text = params["text"] as? String else {
            throw ForgeRPCError.invalidParams("'text' is required")
        }
        try requireScope(sessionID: sid, params: params)
        let view = try resolveOrMaterialize(sessionID: sid)
        view.sendInput(text)
        return ["ok": true]
    }
}

// MARK: - terminal.send_key

/// Send a single keystroke. Recognised names: `Return`, `Enter`, `Tab`,
/// `Escape`, `Backspace`, `Delete`, `Up`, `Down`, `Left`, `Right`, `Space`,
/// `Ctrl-<letter>` (e.g. `Ctrl-C`).
///
/// Params: `{session_id: string, key: string}`
@MainActor
enum TerminalSendKey: ForgeRPCMethod {
    static let name = "terminal.send_key"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        guard let sid = (params["session_id"] as? String).flatMap(UUID.init(uuidString:)) else {
            throw ForgeRPCError.invalidParams("'session_id' is required")
        }
        guard let key = params["key"] as? String, !key.isEmpty else {
            throw ForgeRPCError.invalidParams("'key' is required")
        }
        guard let sequence = Self.keySequence(for: key) else {
            throw ForgeRPCError.invalidParams("Unknown key: \(key)")
        }
        try requireScope(sessionID: sid, params: params)
        let view = try resolveOrMaterialize(sessionID: sid)
        view.sendInput(sequence)
        return ["ok": true]
    }

    /// Translate a named key to the byte sequence Forge's terminal expects.
    /// Control keys become C0 control codes; arrow keys become the standard
    /// VT100 CSI sequences.
    private static func keySequence(for key: String) -> String? {
        switch key.lowercased() {
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return "\u{1B}"
        case "backspace": return "\u{7F}"
        case "delete", "del": return "\u{1B}[3~"
        case "up": return "\u{1B}[A"
        case "down": return "\u{1B}[B"
        case "right": return "\u{1B}[C"
        case "left": return "\u{1B}[D"
        case "space": return " "
        default:
            // Ctrl-<letter> → C0 control code.
            if key.lowercased().hasPrefix("ctrl-"),
               let letter = key.dropFirst(5).lowercased().first,
               let ascii = letter.asciiValue,
               ascii >= 0x61, ascii <= 0x7A
            {
                return String(UnicodeScalar(ascii - 0x60))
            }
            return nil
        }
    }
}

// MARK: - terminal.open_agent

/// Spawn a new agent tab. Replaces the legacy `open_agent` socket envelope.
///
/// Params: `{agent_command: string, workspace_id?: string}`
@MainActor
enum TerminalOpenAgent: ForgeRPCMethod {
    static let name = "terminal.open_agent"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        guard let agentCommand = params["agent_command"] as? String else {
            throw ForgeRPCError.invalidParams("'agent_command' is required")
        }
        guard let agent = AgentStore.shared.agents.first(where: { $0.command == agentCommand }) else {
            throw ForgeRPCError.notFound("No agent with command '\(agentCommand)'")
        }
        let store = ProjectStore.shared
        let resolved = store.activeProject.map { agent.applying(projectID: $0.id) } ?? agent
        let dir = store.effectivePath ?? NSHomeDirectory()

        TerminalSessionManager.shared.createSession(
            workingDirectory: dir,
            title: resolved.name,
            launchCommand: resolved.fullCommand,
            closeOnExit: true,
            projectID: store.activeProjectID,
            workspaceID: store.activeWorkspaceID,
            icon: resolved.icon
        )
        return ["ok": true]
    }
}

// MARK: - Helpers

/// If the caller passed `workspace_id` and/or `project_id`, verify the session
/// belongs to that scope. No-op when neither param is present, so callers that
/// only know a session ID still work. Guards against confused-deputy mistakes
/// where a hook script holds a stale `FORGE_SESSION` and ends up driving a
/// terminal in a different workspace than it intended.
@MainActor
private func requireScope(sessionID: UUID, params: [String: Any]) throws {
    let expectedWorkspace = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
    let expectedProject = (params["project_id"] as? String).flatMap(UUID.init(uuidString:))
    guard expectedWorkspace != nil || expectedProject != nil else { return }

    guard let tab = TerminalSessionManager.shared.tabs.first(where: {
        $0.paneManager?.allSessionIDs.contains(sessionID) == true
            || $0.sessionIDs.contains(sessionID)
    }) else {
        throw ForgeRPCError.notFound("No session \(sessionID.uuidString)")
    }

    if let expectedWorkspace, tab.workspaceID != expectedWorkspace {
        throw ForgeRPCError.invalidParams(
            "Session \(sessionID.uuidString) does not belong to workspace \(expectedWorkspace.uuidString)"
        )
    }
    if let expectedProject, tab.projectID != expectedProject {
        throw ForgeRPCError.invalidParams(
            "Session \(sessionID.uuidString) does not belong to project \(expectedProject.uuidString)"
        )
    }
}

/// Look up the terminal view for a session, materialising it (creating the
/// `GhosttyTerminalView` and starting the shell) if it hasn't been rendered
/// yet. Used by `terminal.send_text` / `terminal.send_key` so agents can drive
/// background-workspace terminals without the user having to open that tab
/// first. Throws `not_found` only when the session ID itself is unknown.
@MainActor
private func resolveOrMaterialize(sessionID: UUID) throws -> GhosttyTerminalView {
    if let existing = TerminalCache.shared.view(for: sessionID) {
        return existing
    }
    guard let session = TerminalSessionManager.shared.session(for: sessionID) else {
        throw ForgeRPCError.notFound("No session \(sessionID.uuidString)")
    }
    return TerminalCache.shared.terminalView(for: session)
}
