import Foundation

struct Project: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var defaultBranch: String
    var createdAt: Date
    var lastActiveAt: Date?

    init(id: UUID = UUID(), name: String, path: String, defaultBranch: String = "main", createdAt: Date = Date(), lastActiveAt: Date? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    init(url: URL) {
        id = UUID()
        name = url.lastPathComponent
        path = url.path
        defaultBranch = Git.shared.currentBranch(in: url.path) ?? "main"
        createdAt = Date()
        lastActiveAt = Date()
    }
}
