import Foundation

// MARK: - TabKind

enum TabKind: Codable, Hashable {
    case terminal
    case changes(repoPath: String)
    case workspaceDiff(repoPath: String, baseRef: String)

    /// Diff tabs are transient — default to terminal when decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self), raw == "terminal" {
            self = .terminal
        } else {
            self = .terminal // Diff tabs aren't persisted; default to terminal
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .terminal:
            try container.encode("terminal")
        case .changes:
            try container.encode("terminal") // Don't persist diff tabs
        case .workspaceDiff:
            try container.encode("terminal") // Don't persist diff tabs
        }
    }

    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    var isChanges: Bool {
        if case .changes = self { return true }
        return false
    }

    var isWorkspaceDiff: Bool {
        if case .workspaceDiff = self { return true }
        return false
    }
}

// MARK: - TerminalTab

struct TerminalTab: Identifiable, Codable {
    let id: UUID
    var projectID: UUID?
    var workspaceID: UUID?
    var title: String
    var icon: String?
    var kind: TabKind

    /// Session IDs in this tab (for persistence). At runtime, BonsplitPaneManager owns the layout.
    var sessionIDs: [UUID]

    /// The BonsplitPaneManager for this tab. Not persisted — recreated on restore.
    var paneManager: BonsplitPaneManager?

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        workspaceID: UUID? = nil,
        sessionID: UUID,
        title: String = "Shell",
        icon: String? = nil,
        kind: TabKind = .terminal
    ) {
        self.id = id
        self.projectID = projectID
        self.workspaceID = workspaceID
        self.title = title
        self.icon = icon
        self.kind = kind
        sessionIDs = kind.isTerminal ? [sessionID] : []
    }

    // MARK: - Codable (paneManager is excluded)

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case workspaceID
        case title
        case icon
        case kind
        case sessionIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        kind = (try? container.decode(TabKind.self, forKey: .kind)) ?? .terminal

        sessionIDs = (try? container.decode([UUID].self, forKey: .sessionIDs)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encode(kind, forKey: .kind)
        // Persist stored session list (paneManager is runtime-only)
        try container.encode(sessionIDs, forKey: .sessionIDs)
    }
}
