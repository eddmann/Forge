import Foundation
import SwiftUI

// MARK: - FileChangeType

enum FileChangeType: String, Hashable, CaseIterable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"
    case typeChanged = "T"
    case untracked = "?"

    var symbol: String {
        switch self {
        case .modified: "pencil.circle.fill"
        case .added: "plus.circle.fill"
        case .deleted: "minus.circle.fill"
        case .renamed: "arrow.right.circle.fill"
        case .copied: "doc.on.doc.fill"
        case .unmerged: "exclamationmark.triangle.fill"
        case .typeChanged: "arrow.triangle.2.circlepath.circle.fill"
        case .untracked: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .modified: .orange
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .copied: .cyan
        case .unmerged: .yellow
        case .typeChanged: .yellow
        case .untracked: Color(nsColor: .secondaryLabelColor)
        }
    }

    var label: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .unmerged: "Conflict"
        case .typeChanged: "Type Changed"
        case .untracked: "Untracked"
        }
    }

    var shortLabel: String {
        rawValue
    }

    init?(code: Character) {
        switch code {
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .unmerged
        case "T": self = .typeChanged
        case "?": self = .untracked
        case "!": return nil // ignored
        default: return nil
        }
    }
}

// MARK: - FileStatus

struct FileStatus: Identifiable, Hashable {
    let path: String
    let indexStatus: FileChangeType?
    let workTreeStatus: FileChangeType?
    let originalPath: String?

    var id: String {
        path
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir
    }

    var isUntracked: Bool {
        indexStatus == .untracked || workTreeStatus == .untracked
    }

    var isConflicted: Bool {
        indexStatus == .unmerged || workTreeStatus == .unmerged
    }

    var isStaged: Bool {
        guard !isUntracked, !isConflicted else { return false }
        return indexStatus != nil
    }

    var isUnstaged: Bool {
        guard !isUntracked, !isConflicted else { return false }
        return workTreeStatus != nil
    }

    /// Primary change type to display — prefers staged if available.
    var displayChangeType: FileChangeType {
        indexStatus ?? workTreeStatus ?? .modified
    }
}

// MARK: - WorkingTreeGroup

enum WorkingTreeGroup: String, CaseIterable {
    case conflicts
    case staged
    case unstaged
    case untracked

    var label: String {
        switch self {
        case .conflicts: "Merge Conflicts"
        case .staged: "Staged Changes"
        case .unstaged: "Changes"
        case .untracked: "Untracked Files"
        }
    }

    var accentColor: Color {
        switch self {
        case .conflicts: .red
        case .staged: .green
        case .unstaged: .orange
        case .untracked: Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Categorization

extension FileStatus {
    /// Buckets a flat list of file statuses into groups.
    static func categorize(_ statuses: [FileStatus]) -> [WorkingTreeGroup: [FileStatus]] {
        var result: [WorkingTreeGroup: [FileStatus]] = [:]

        for status in statuses {
            if status.isConflicted {
                result[.conflicts, default: []].append(status)
            } else if status.isUntracked {
                result[.untracked, default: []].append(status)
            } else {
                if status.isStaged {
                    result[.staged, default: []].append(status)
                }
                if status.isUnstaged {
                    result[.unstaged, default: []].append(status)
                }
            }
        }

        return result
    }
}

// MARK: - Porcelain Parsing

extension FileStatus {
    /// Parses `git status --porcelain` output into an array of FileStatus.
    static func parse(porcelain output: String) -> [FileStatus] {
        var results: [FileStatus] = []
        let lines = output.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            guard line.count >= 3 else {
                i += 1
                continue
            }

            let x = line[line.startIndex]
            let y = line[line.index(after: line.startIndex)]
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            var path = String(line[pathStart...])
            var originalPath: String?

            // Handle renames/copies: "R  new\0old" or "R  old -> new"
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if let arrowRange = path.range(of: " -> ") {
                    originalPath = String(path[path.startIndex ..< arrowRange.lowerBound])
                    path = String(path[arrowRange.upperBound...])
                } else if i + 1 < lines.count {
                    // Check if next line is the original path (null-separated)
                    let nextLine = lines[i + 1]
                    if nextLine.count < 3 || (nextLine.count >= 3 && nextLine[nextLine.index(nextLine.startIndex, offsetBy: 2)] != " ") {
                        originalPath = nextLine
                        i += 1
                    }
                }
            }

            // Untracked files: both columns are "?"
            if x == "?", y == "?" {
                results.append(FileStatus(
                    path: path,
                    indexStatus: nil,
                    workTreeStatus: .untracked,
                    originalPath: nil
                ))
            } else {
                results.append(FileStatus(
                    path: path,
                    indexStatus: x == " " ? nil : FileChangeType(code: x),
                    workTreeStatus: y == " " ? nil : FileChangeType(code: y),
                    originalPath: originalPath
                ))
            }

            i += 1
        }

        return results
    }
}
