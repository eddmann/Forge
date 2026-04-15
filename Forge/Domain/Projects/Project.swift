import Foundation

/// Distinguishes a regular Forge project from a scratch project.
///
/// When `kind == .scratch`:
/// - `project.path == workspace.path` (the project and its lone workspace share one directory on disk)
/// - Exactly one workspace exists for the project
/// - No git remote; `parentBranch == branch` (whatever git's `init.defaultBranch` produced)
/// - Selecting a scratch sets both `activeProjectID` and `activeWorkspaceID` together
/// - Diff/merge/commit-count features are degenerate — hidden in UI, guarded in code
enum ProjectKind: String, Codable {
    case normal
    case scratch
}

struct Project: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var defaultBranch: String
    var createdAt: Date
    var lastActiveAt: Date?
    var kind: ProjectKind

    var isScratch: Bool {
        kind == .scratch
    }

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        defaultBranch: String = "main",
        createdAt: Date = Date(),
        lastActiveAt: Date? = nil,
        kind: ProjectKind = .normal
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.kind = kind
    }

    init(url: URL) {
        id = UUID()
        name = url.lastPathComponent
        path = url.path
        defaultBranch = Git.shared.currentBranch(in: url.path) ?? "main"
        createdAt = Date()
        lastActiveAt = Date()
        kind = .normal
    }
}
