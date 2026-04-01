import Foundation

struct GitUnifiedDiffParser {
    func parse(_ patch: String) -> GitDiffResult {
        let normalized = patch.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var files: [GitFileDiff] = []
        var currentFile: FileAccumulator?
        var currentHunk: HunkAccumulator?
        var pendingOldLine: Int?
        var pendingNewLine: Int?

        func finalizeHunk() {
            guard let hunk = currentHunk else { return }
            currentFile?.hunks.append(
                GitDiffHunk(
                    id: hunk.id,
                    oldStart: hunk.oldStart,
                    oldCount: hunk.oldCount,
                    newStart: hunk.newStart,
                    newCount: hunk.newCount,
                    header: hunk.header,
                    rawHeader: hunk.rawHeader,
                    lines: hunk.lines
                )
            )
            currentHunk = nil
            pendingOldLine = nil
            pendingNewLine = nil
        }

        func finalizeFile() {
            finalizeHunk()
            guard let file = currentFile else { return }
            files.append(file.build())
            currentFile = nil
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                finalizeFile()
                currentFile = FileAccumulator()
            }

            currentFile?.patchLines.append(line)
            guard currentFile != nil else { continue }

            if line.hasPrefix("diff --git ") {
                let parsed = parseDiffGitHeader(line)
                currentFile?.oldPath = parsed.oldPath
                currentFile?.newPath = parsed.newPath
                continue
            }

            if line.hasPrefix("new file mode ") {
                currentFile?.change = .added
                continue
            }

            if line.hasPrefix("deleted file mode ") {
                currentFile?.change = .deleted
                continue
            }

            if line.hasPrefix("rename from ") {
                currentFile?.oldPath = String(line.dropFirst("rename from ".count))
                currentFile?.change = .renamed
                continue
            }

            if line.hasPrefix("rename to ") {
                currentFile?.newPath = String(line.dropFirst("rename to ".count))
                currentFile?.change = .renamed
                continue
            }

            if line.hasPrefix("copy from ") {
                currentFile?.oldPath = String(line.dropFirst("copy from ".count))
                currentFile?.change = .copied
                continue
            }

            if line.hasPrefix("copy to ") {
                currentFile?.newPath = String(line.dropFirst("copy to ".count))
                currentFile?.change = .copied
                continue
            }

            if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                currentFile?.isBinary = true
                continue
            }

            if line.hasPrefix("--- ") {
                currentFile?.oldPath = parsePatchPath(String(line.dropFirst(4)))
                continue
            }

            if line.hasPrefix("+++ ") {
                currentFile?.newPath = parsePatchPath(String(line.dropFirst(4)))
                continue
            }

            if line.hasPrefix("@@ ") {
                finalizeHunk()
                guard let header = parseHunkHeader(line) else { continue }
                currentHunk = HunkAccumulator(
                    id: "\(files.count)-\(currentFile?.hunks.count ?? 0)",
                    oldStart: header.oldStart,
                    oldCount: header.oldCount,
                    newStart: header.newStart,
                    newCount: header.newCount,
                    header: line,
                    rawHeader: line
                )
                pendingOldLine = header.oldStart
                pendingNewLine = header.newStart
                continue
            }

            guard let prefix = line.first, currentHunk != nil else { continue }
            switch prefix {
            case " ":
                appendLine(
                    GitDiffLine(
                        id: makeLineID(fileCount: files.count),
                        kind: .context,
                        oldLineNumber: pendingOldLine,
                        newLineNumber: pendingNewLine,
                        text: String(line.dropFirst()),
                        rawLine: line
                    ),
                    to: &currentHunk
                )
                pendingOldLine = pendingOldLine.map { $0 + 1 }
                pendingNewLine = pendingNewLine.map { $0 + 1 }
            case "-":
                appendLine(
                    GitDiffLine(
                        id: makeLineID(fileCount: files.count),
                        kind: .removed,
                        oldLineNumber: pendingOldLine,
                        newLineNumber: nil,
                        text: String(line.dropFirst()),
                        rawLine: line
                    ),
                    to: &currentHunk
                )
                pendingOldLine = pendingOldLine.map { $0 + 1 }
            case "+":
                appendLine(
                    GitDiffLine(
                        id: makeLineID(fileCount: files.count),
                        kind: .added,
                        oldLineNumber: nil,
                        newLineNumber: pendingNewLine,
                        text: String(line.dropFirst()),
                        rawLine: line
                    ),
                    to: &currentHunk
                )
                pendingNewLine = pendingNewLine.map { $0 + 1 }
            case "\\":
                // Mark the previous line as missing trailing newline
                if var hunk = currentHunk, var lastLine = hunk.lines.last {
                    lastLine.hasTrailingNewline = false
                    hunk.lines[hunk.lines.count - 1] = lastLine
                    currentHunk = hunk
                }
                appendLine(
                    GitDiffLine(
                        id: makeLineID(fileCount: files.count),
                        kind: .noNewlineMarker,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        text: line,
                        rawLine: line,
                        hasTrailingNewline: false
                    ),
                    to: &currentHunk
                )
            default:
                break
            }
        }

        finalizeFile()

        let stats = GitDiffStats(
            filesChanged: files.count,
            insertions: files.reduce(0) { partial, file in
                partial + file.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
            },
            deletions: files.reduce(0) { partial, file in
                partial + file.hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count }
            }
        )

        return GitDiffResult(files: files, rawPatch: normalized, stats: stats)
    }

    private func parseDiffGitHeader(_ line: String) -> (oldPath: String?, newPath: String?) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return (nil, nil) }
        return (
            stripGitPrefix(String(parts[2])),
            stripGitPrefix(String(parts[3]))
        )
    }

    private func stripGitPrefix(_ value: String) -> String? {
        if value == "/dev/null" {
            return nil
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            return String(value.dropFirst(2))
        }
        return value
    }

    private func parsePatchPath(_ value: String) -> String? {
        stripGitPrefix(value)
    }

    private func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard let secondAt = line.dropFirst(2).range(of: "@@") else { return nil }
        let headerBody = String(line[..<secondAt.upperBound])
        let parts = headerBody
            .replacingOccurrences(of: "@@", with: "")
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")

        guard parts.count >= 2 else { return nil }
        guard let oldRange = parseRange(String(parts[0])),
              let newRange = parseRange(String(parts[1]))
        else {
            return nil
        }
        return (oldRange.start, oldRange.count, newRange.start, newRange.count)
    }

    private func parseRange(_ value: String) -> (start: Int, count: Int)? {
        guard value.count >= 2 else { return nil }
        let body = value.dropFirst()
        let pieces = body.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(pieces[0]) else { return nil }
        let count = pieces.count > 1 ? (Int(pieces[1]) ?? 1) : 1
        return (start, count)
    }

    private func makeLineID(fileCount: Int) -> String {
        "\(fileCount)-\(UUID().uuidString)"
    }

    private func appendLine(_ line: GitDiffLine, to hunk: inout HunkAccumulator?) {
        guard var current = hunk else { return }
        current.lines.append(line)
        hunk = current
    }
}

private struct FileAccumulator {
    var oldPath: String?
    var newPath: String?
    var change: GitFileChangeKind = .modified
    var isBinary = false
    var hunks: [GitDiffHunk] = []
    var patchLines: [String] = []

    func build() -> GitFileDiff {
        var resolvedChange = change
        if oldPath == nil {
            resolvedChange = .added
        } else if newPath == nil {
            resolvedChange = .deleted
        } else if resolvedChange == .modified, oldPath != newPath {
            resolvedChange = .renamed
        }

        return GitFileDiff(
            oldPath: oldPath,
            newPath: newPath,
            change: resolvedChange,
            isBinary: isBinary,
            hunks: hunks,
            patch: patchLines.joined(separator: "\n")
        )
    }
}

private struct HunkAccumulator {
    var id: String
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var header: String
    var rawHeader: String
    var lines: [GitDiffLine] = []
}
