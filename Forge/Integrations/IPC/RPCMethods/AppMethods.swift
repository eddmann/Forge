import AppKit
import Foundation
import UserNotifications

// MARK: - app.notify

/// Fires an in-app toast + system notification. Both are ephemeral — Forge does
/// not currently persist notifications for later review.
///
/// Params: `{title: string, subtitle?: string, body?: string}`
@MainActor
enum AppNotify: ForgeRPCMethod {
    static let name = "app.notify"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        guard let title = params["title"] as? String, !title.isEmpty else {
            throw ForgeRPCError.invalidParams("'title' is required")
        }
        let subtitle = params["subtitle"] as? String
        let body = params["body"] as? String

        // In-app toast
        let toastMessage: String = if let body, !body.isEmpty {
            "\(title): \(body)"
        } else {
            title
        }
        ToastManager.shared.show(toastMessage)

        // System notification
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        if let body { content.body = body }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)

        return ["ok": true]
    }
}

// MARK: - app.tree

/// Dumps the current UI topology as a JSON tree. Optional `workspace_id` param
/// filters to a single workspace's sessions.
///
/// Shape: `{projects: [...], workspaces: [...], sessions: [{id, workspace_id, tab_id, title, working_directory}]}`
@MainActor
enum AppTree: ForgeRPCMethod {
    static let name = "app.tree"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        let store = ProjectStore.shared
        let filterWorkspace = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:))

        let projects: [[String: Any]] = store.projects.map { p in
            [
                "id": p.id.uuidString,
                "name": p.name,
                "path": p.path,
                "default_branch": p.defaultBranch
            ]
        }
        let workspaces: [[String: Any]] = store.workspaces
            .filter { filterWorkspace == nil || $0.id == filterWorkspace }
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

        // Flatten sessions across tabs (includes pane manager sub-sessions).
        var sessions: [[String: Any]] = []
        for tab in TerminalSessionManager.shared.tabs {
            let workspaceID = tab.workspaceID
            if let filterWorkspace, workspaceID != filterWorkspace { continue }
            let sessionIDs = tab.paneManager.map { Array($0.allSessionIDs) } ?? tab.sessionIDs
            for sid in sessionIDs {
                guard let session = TerminalSessionManager.shared.session(for: sid) else { continue }
                var dict: [String: Any] = [
                    "id": session.id.uuidString,
                    "tab_id": tab.id.uuidString,
                    "title": session.title ?? NSNull(),
                    "working_directory": session.workingDirectory
                ]
                dict["workspace_id"] = workspaceID?.uuidString ?? NSNull()
                sessions.append(dict)
            }
        }

        return [
            "projects": projects,
            "workspaces": workspaces,
            "sessions": sessions
        ]
    }
}

// MARK: - app.log

/// Append an entry to the workspace activity log so agents can record
/// checkpoints that aren't covered by hook events (e.g. "finished step 3 of 7").
///
/// Params: `{message: string, workspace_id?: string, level?: "info"|"warn"|"error"}`
/// If `workspace_id` is omitted, falls through to the currently active workspace.
@MainActor
enum AppLog: ForgeRPCMethod {
    static let name = "app.log"

    static func handle(params: [String: Any]) async throws -> [String: Any] {
        guard let message = params["message"] as? String, !message.isEmpty else {
            throw ForgeRPCError.invalidParams("'message' is required")
        }
        let level = (params["level"] as? String) ?? "info"
        let workspaceID = (params["workspace_id"] as? String).flatMap(UUID.init(uuidString:))
            ?? ProjectStore.shared.activeWorkspaceID
        guard let workspaceID else {
            throw ForgeRPCError.invalidParams("No workspace_id provided and no active workspace")
        }

        let event = ActivityEvent(
            kind: .agentUpdate,
            title: message,
            metadata: ["source": "cli", "level": level]
        )
        ActivityLogStore.shared.append(workspaceID: workspaceID, event: event)
        return ["ok": true, "event_id": event.id.uuidString]
    }
}
