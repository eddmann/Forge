import Foundation

// MARK: - WordDiffSegment

struct WordDiffSegment: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: SegmentKind

    enum SegmentKind: Equatable {
        case equal
        case added
        case removed
    }
}

// MARK: - WordDiff

enum WordDiff {
    /// Computes word-level differences between two strings.
    static func compute(oldLine: String, newLine: String) -> (old: [WordDiffSegment], new: [WordDiffSegment]) {
        let oldWords = tokenize(oldLine)
        let newWords = tokenize(newLine)
        let lcs = longestCommonSubsequence(oldWords, newWords)

        var oldSegments: [WordDiffSegment] = []
        var newSegments: [WordDiffSegment] = []
        var segmentID = 0

        var oldIndex = 0
        var newIndex = 0
        var lcsIndex = 0

        while oldIndex < oldWords.count || newIndex < newWords.count {
            if lcsIndex < lcs.count {
                while oldIndex < oldWords.count, oldWords[oldIndex] != lcs[lcsIndex] {
                    oldSegments.append(WordDiffSegment(id: segmentID, text: oldWords[oldIndex], kind: .removed))
                    segmentID += 1
                    oldIndex += 1
                }
                while newIndex < newWords.count, newWords[newIndex] != lcs[lcsIndex] {
                    newSegments.append(WordDiffSegment(id: segmentID, text: newWords[newIndex], kind: .added))
                    segmentID += 1
                    newIndex += 1
                }
                if oldIndex < oldWords.count, newIndex < newWords.count {
                    oldSegments.append(WordDiffSegment(id: segmentID, text: oldWords[oldIndex], kind: .equal))
                    segmentID += 1
                    newSegments.append(WordDiffSegment(id: segmentID, text: newWords[newIndex], kind: .equal))
                    segmentID += 1
                    oldIndex += 1
                    newIndex += 1
                    lcsIndex += 1
                }
            } else {
                while oldIndex < oldWords.count {
                    oldSegments.append(WordDiffSegment(id: segmentID, text: oldWords[oldIndex], kind: .removed))
                    segmentID += 1
                    oldIndex += 1
                }
                while newIndex < newWords.count {
                    newSegments.append(WordDiffSegment(id: segmentID, text: newWords[newIndex], kind: .added))
                    segmentID += 1
                    newIndex += 1
                }
            }
        }

        return (oldSegments, newSegments)
    }

    /// Computes word diff segments for a single line given its pair.
    static func computeForLine(content: String, pairContent: String?, isAddition: Bool) -> [WordDiffSegment] {
        guard let pairContent else {
            return [WordDiffSegment(id: 0, text: content, kind: isAddition ? .added : .removed)]
        }
        let (oldSegments, newSegments) = isAddition
            ? compute(oldLine: pairContent, newLine: content)
            : compute(oldLine: content, newLine: pairContent)
        return isAddition ? newSegments : oldSegments
    }

    // MARK: - Private

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inWhitespace = false

        for char in text {
            let ws = char.isWhitespace
            if ws != inWhitespace, !current.isEmpty {
                tokens.append(current)
                current = ""
            }
            current.append(char)
            inWhitespace = ws
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        guard m > 0, n > 0 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1 ... m {
            for j in 1 ... n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var lcs: [String] = []
        var i = m, j = n
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.insert(a[i - 1], at: 0)
                i -= 1; j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return lcs
    }
}

// MARK: - Hunk Line Pairing & Pre-computed Word Diffs

extension GitDiffHunk {
    /// Pre-computes word-level diff segments for all paired lines in this hunk.
    /// Call once per hunk outside the view body, then pass segments to line rows.
    func preparedWordDiffs() -> [String: [WordDiffSegment]] {
        var segments: [String: [WordDiffSegment]] = [:]
        var i = 0

        while i < lines.count {
            if lines[i].kind == .removed {
                var deletions: [GitDiffLine] = []
                var j = i
                while j < lines.count, lines[j].kind == .removed {
                    deletions.append(lines[j])
                    j += 1
                }
                var additions: [GitDiffLine] = []
                while j < lines.count, lines[j].kind == .added {
                    additions.append(lines[j])
                    j += 1
                }
                let pairCount = min(deletions.count, additions.count)
                for k in 0 ..< pairCount {
                    let (oldSegs, newSegs) = WordDiff.compute(
                        oldLine: deletions[k].text,
                        newLine: additions[k].text
                    )
                    segments[deletions[k].id] = oldSegs
                    segments[additions[k].id] = newSegs
                }
                i = j
            } else {
                i += 1
            }
        }

        return segments
    }
}
