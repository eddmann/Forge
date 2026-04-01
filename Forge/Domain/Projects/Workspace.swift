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
        createdAt: Date = Date()
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
    }
}
