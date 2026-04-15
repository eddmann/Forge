import Foundation

// MARK: - ActivityEventKind

enum ActivityEventKind: String, Codable {
    case workspaceCreated
    case workspaceMerged
    case scratchCreated
    case agentUpdate
    case reviewSent

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "agentSessionStart", "agentSnapshot", "agentSessionEnd":
            self = .agentUpdate
        default:
            guard let kind = ActivityEventKind(rawValue: raw) else {
                throw try DecodingError.dataCorruptedError(
                    in: decoder.singleValueContainer(),
                    debugDescription: "Unknown ActivityEventKind: \(raw)"
                )
            }
            self = kind
        }
    }
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
