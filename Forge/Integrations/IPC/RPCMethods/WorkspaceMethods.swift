import Foundation

// MARK: - workspace.list

@MainActor
enum WorkspaceList: ForgeRPCMethod {
    static let name = "workspace.list"

    static func handle(params: [String: Any]) throws -> [String: Any] {
        let store = ProjectStore.shared
        let filterProject = (params["project_id"] as? String).flatMap(UUID.init(uuidString:))

        let workspaces: [[String: Any]] = store.workspaces
            .filter { filterProject == nil || $0.projectID == filterProject }
            .map { w in
                [
                    "id": w.id.uuidString,
                    "name": w.name,
                    "branch": w.branch,
                    "parent_branch": w.parentBranch,
                    "path": w.path,
                    "project_id": w.projectID.uuidString,
                    "status": w.status.rawValue
                ]
            }
        return ["workspaces": workspaces]
    }
}

// MARK: - workspace.current

@MainActor
enum WorkspaceCurrent: ForgeRPCMethod {
    static let name = "workspace.current"

    static func handle(params _: [String: Any]) throws -> [String: Any] {
        guard let ws = ProjectStore.shared.activeWorkspace else {
            return ["workspace": NSNull()]
        }
        return [
            "workspace": [
                "id": ws.id.uuidString,
                "name": ws.name,
                "branch": ws.branch,
                "parent_branch": ws.parentBranch,
                "path": ws.path,
                "project_id": ws.projectID.uuidString,
                "status": ws.status.rawValue
            ]
        ]
    }
}

// MARK: - workspace.select

/// Switch the active workspace. Also sets the active project to its parent so
/// the sidebar selection is coherent.
@MainActor
enum WorkspaceSelect: ForgeRPCMethod {
    static let name = "workspace.select"

    static func handle(params: [String: Any]) throws -> [String: Any] {
        guard let idString = params["workspace_id"] as? String,
              let id = UUID(uuidString: idString)
        else {
            throw ForgeRPCError.invalidParams("'workspace_id' is required")
        }
        let store = ProjectStore.shared
        guard let workspace = store.workspaces.first(where: { $0.id == id }) else {
            throw ForgeRPCError.notFound("No workspace with id \(idString)")
        }
        store.activeProjectID = workspace.projectID
        store.activeWorkspaceID = workspace.id
        return ["ok": true]
    }
}
