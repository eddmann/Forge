import Foundation

// MARK: - system.ping

@MainActor
enum SystemPing: ForgeRPCMethod {
    static let name = "system.ping"

    static func handle(params _: [String: Any]) throws -> [String: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return [
            "version": version,
            "build": build,
            "uptime_seconds": Int(ProcessInfo.processInfo.systemUptime)
        ]
    }
}

// MARK: - system.identify

/// Resolves the caller's scope (project / workspace / session) from explicit
/// params, and returns full metadata about each. Used by clients to confirm
/// what scope a command would target before issuing it.
@MainActor
enum SystemIdentify: ForgeRPCMethod {
    static let name = "system.identify"

    static func handle(params: [String: Any]) throws -> [String: Any] {
        let store = ProjectStore.shared

        // Resolve session
        var resolvedSession: [String: Any] = [:]
        if let sidString = params["session_id"] as? String,
           let sid = UUID(uuidString: sidString),
           let session = TerminalSessionManager.shared.session(for: sid)
        {
            resolvedSession = [
                "id": session.id.uuidString,
                "title": session.title ?? NSNull(),
                "working_directory": session.workingDirectory
            ]
        }

        // Resolve workspace
        var resolvedWorkspace: [String: Any] = [:]
        let workspaceID = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
            ?? store.activeWorkspaceID
        if let wid = workspaceID,
           let ws = store.workspaces.first(where: { $0.id == wid })
        {
            resolvedWorkspace = [
                "id": ws.id.uuidString,
                "name": ws.name,
                "branch": ws.branch,
                "path": ws.path,
                "project_id": ws.projectID.uuidString
            ]
        }

        // Resolve project
        var resolvedProject: [String: Any] = [:]
        let projectID = (params["project_id"] as? String).flatMap(UUID.init(uuidString:))
            ?? store.activeProjectID
        if let pid = projectID,
           let project = store.projects.first(where: { $0.id == pid })
        {
            resolvedProject = [
                "id": project.id.uuidString,
                "name": project.name,
                "path": project.path
            ]
        }

        return [
            "session": resolvedSession,
            "workspace": resolvedWorkspace,
            "project": resolvedProject
        ]
    }
}

// MARK: - system.capabilities

/// Returns the protocol version and a sorted list of supported method names so
/// older CLIs can degrade gracefully when newer methods are added.
@MainActor
enum SystemCapabilities: ForgeRPCMethod {
    static let name = "system.capabilities"

    static func handle(params _: [String: Any]) throws -> [String: Any] {
        [
            "protocol_version": ForgeRPC.protocolVersion,
            "methods": ForgeRPC.methods.keys.sorted()
        ]
    }
}
