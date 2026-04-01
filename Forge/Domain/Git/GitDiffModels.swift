import Foundation

enum GitDiffEndpoint: Hashable {
    case workingTree
    case index
    case revision(String)
}

struct GitDiffRequest: Hashable {
    var base: GitDiffEndpoint
    var head: GitDiffEndpoint
    var contextLines: Int = 3
    var paths: [String] = []

    static func unstaged(paths: [String] = [], contextLines: Int = 3) -> GitDiffRequest {
        GitDiffRequest(base: .index, head: .workingTree, contextLines: contextLines, paths: paths)
    }

    static func staged(paths: [String] = [], contextLines: Int = 3) -> GitDiffRequest {
        GitDiffRequest(base: .revision("HEAD"), head: .index, contextLines: contextLines, paths: paths)
    }

    static func between(
        _ baseRef: String,
        _ headRef: String,
        paths: [String] = [],
        contextLines: Int = 3
    ) -> GitDiffRequest {
        GitDiffRequest(base: .revision(baseRef), head: .revision(headRef), contextLines: contextLines, paths: paths)
    }

    static func from(
        _ baseRef: String,
        toWorkingTree paths: [String] = [],
        contextLines: Int = 3
    ) -> GitDiffRequest {
        GitDiffRequest(base: .revision(baseRef), head: .workingTree, contextLines: contextLines, paths: paths)
    }
}

struct GitDiffResult: Hashable {
    var files: [GitFileDiff]
    var rawPatch: String
    var stats: GitDiffStats
}

struct GitDiffStats: Hashable {
    var filesChanged: Int
    var insertions: Int
    var deletions: Int
}

struct GitFileDiff: Identifiable, Hashable {
    var id: String {
        [
            oldPath ?? "",
            newPath ?? "",
            change.rawValue
        ].joined(separator: "|")
    }

    var oldPath: String?
    var newPath: String?
    var change: GitFileChangeKind
    var isBinary: Bool
    var hunks: [GitDiffHunk]
    var patch: String
    var similarity: Int?

    var additions: Int {
        hunks.reduce(into: 0) { $0 += $1.additions }
    }

    var deletions: Int {
        hunks.reduce(into: 0) { $0 += $1.deletions }
    }

    var fileName: String {
        ((newPath ?? oldPath) as NSString?)?.lastPathComponent ?? ""
    }

    var directory: String {
        let dir = ((newPath ?? oldPath) as NSString?)?.deletingLastPathComponent ?? ""
        return dir.isEmpty ? "" : dir
    }

    var isPureRename: Bool {
        change == .renamed && similarity == 100
    }
}

enum GitFileChangeKind: String, Hashable {
    case added
    case modified
    case deleted
    case renamed
    case copied
}

struct GitDiffHunk: Identifiable, Hashable {
    var id: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var header: String
    var rawHeader: String
    var lines: [GitDiffLine]

    var additions: Int {
        lines.filter { $0.kind == .added }.count
    }

    var deletions: Int {
        lines.filter { $0.kind == .removed }.count
    }

    /// Generates a full patch for this hunk suitable for `git apply --cached`.
    func toPatchString(filePath: String) -> String {
        var patch = "--- a/\(filePath)\n+++ b/\(filePath)\n\(rawHeader)\n"
        for line in lines {
            patch += line.prefix + line.text + "\n"
        }
        return patch
    }

    /// Generates a patch for selected lines only.
    func toPatchString(filePath: String, selectedLineIds: Set<String>, forStaging _: Bool = true) -> String? {
        var patchLines: [GitDiffLine] = []
        var selectedAdditions = 0
        var selectedDeletions = 0

        for line in lines {
            switch line.kind {
            case .context:
                patchLines.append(line)
            case .added:
                if selectedLineIds.contains(line.id) {
                    patchLines.append(line)
                    selectedAdditions += 1
                }
            // Unselected additions are simply skipped
            case .removed:
                if selectedLineIds.contains(line.id) {
                    patchLines.append(line)
                    selectedDeletions += 1
                } else {
                    // Convert unselected deletions to context
                    var contextLine = line
                    contextLine.kind = .context
                    patchLines.append(contextLine)
                }
            case .noNewlineMarker:
                continue
            }
        }

        guard selectedAdditions > 0 || selectedDeletions > 0 else { return nil }

        let newOldCount = patchLines.filter { $0.kind == .context || $0.kind == .removed }.count
        let newNewCount = patchLines.filter { $0.kind == .context || $0.kind == .added }.count
        let hdr = "@@ -\(oldStart),\(newOldCount) +\(newStart),\(newNewCount) @@ \(header)"

        var patch = "--- a/\(filePath)\n+++ b/\(filePath)\n\(hdr)\n"
        for line in patchLines {
            patch += line.prefix + line.text + "\n"
        }
        return patch
    }
}

struct GitDiffLine: Identifiable, Hashable {
    var id: String
    var kind: GitDiffLineKind
    var oldLineNumber: Int?
    var newLineNumber: Int?
    var text: String
    var rawLine: String
    var hasTrailingNewline: Bool

    /// The single-character prefix for this line type.
    var prefix: String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        case .noNewlineMarker: "\\"
        }
    }

    init(
        id: String,
        kind: GitDiffLineKind,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil,
        text: String,
        rawLine: String = "",
        hasTrailingNewline: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.text = text
        self.rawLine = rawLine
        self.hasTrailingNewline = hasTrailingNewline
    }
}

enum GitDiffLineKind: String, Hashable {
    case context
    case added
    case removed
    case noNewlineMarker
}
