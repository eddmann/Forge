import Foundation

struct WorkspaceCommit: Identifiable, Hashable {
    let id: String
    let shortHash: String
    let message: String
    let author: String
    let date: Date

    init(hash: String, message: String, author: String, date: Date) {
        id = hash
        shortHash = String(hash.prefix(7))
        self.message = message
        self.author = author
        self.date = date
    }

    /// Parses commits from `git log --format="%H%n%s%n%an%n%aI"` output.
    /// Each commit is 4 lines: hash, subject, author name, ISO 8601 date.
    static func parse(from output: String) -> [WorkspaceCommit] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var commits: [WorkspaceCommit] = []
        var i = 0
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        while i + 3 < lines.count {
            let hash = lines[i]
            let message = lines[i + 1]
            let author = lines[i + 2]
            let dateStr = lines[i + 3]
            let date = formatter.date(from: dateStr) ?? Date()
            commits.append(WorkspaceCommit(hash: hash, message: message, author: author, date: date))
            i += 4
        }

        return commits
    }
}
