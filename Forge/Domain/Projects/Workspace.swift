import Foundation

struct Workspace: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var projectID: UUID
    var name: String
    var path: String
    var branch: String
    var parentBranch: String
    var status: Status
    var fullClone: Bool
    var createdAt: Date
    var lastActiveAt: Date?
    var allocatedPorts: [String: Int]
    var portDetails: [String: String]

    enum Status: String, Codable {
        case active
        case merged
        case archived
    }

    init(
        id: UUID = UUID(),
        projectID: UUID,
        name: String,
        path: String,
        branch: String,
        parentBranch: String,
        status: Status = .active,
        fullClone: Bool = false,
        createdAt: Date = Date(),
        lastActiveAt: Date? = nil,
        allocatedPorts: [String: Int] = [:],
        portDetails: [String: String] = [:]
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.path = path
        self.branch = branch
        self.parentBranch = parentBranch
        self.status = status
        self.fullClone = fullClone
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.allocatedPorts = allocatedPorts
        self.portDetails = portDetails
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decode(UUID.self, forKey: .projectID)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        branch = try c.decode(String.self, forKey: .branch)
        parentBranch = try c.decode(String.self, forKey: .parentBranch)
        status = try c.decode(Status.self, forKey: .status)
        fullClone = try c.decode(Bool.self, forKey: .fullClone)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt)
        allocatedPorts = try c.decodeIfPresent([String: Int].self, forKey: .allocatedPorts) ?? [:]
        portDetails = try c.decodeIfPresent([String: String].self, forKey: .portDetails) ?? [:]
    }
}
