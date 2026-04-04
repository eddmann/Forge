import Foundation

// MARK: - ActivityEventKind

enum ActivityEventKind: String, Codable {
    case workspaceCreated
    case workspaceMerged
    case agentSessionStart
    case agentSnapshot
    case agentSessionEnd
    case reviewSent
}

// MARK: - ActivityEvent

struct ActivityEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let kind: ActivityEventKind
    var title: String
    var detail: String?
    var metadata: [String: String]
    var isPending: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: ActivityEventKind,
        title: String,
        detail: String? = nil,
        metadata: [String: String] = [:],
        isPending: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.title = title
        self.detail = detail
        self.metadata = metadata
        self.isPending = isPending
    }
}
