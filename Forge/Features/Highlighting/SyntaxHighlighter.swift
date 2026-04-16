import Foundation
import SwiftTreeSitter

final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    /// Skip parsing files larger than this (UTF-8 bytes). Diff highlighting still works for
    /// the file's diff lines without colors.
    private let maxBlobBytes = 1 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.eddmann.forge.syntax", qos: .userInitiated)

    private init() {}

    func highlight(
        oldBlob: String?,
        oldPath: String?,
        newBlob: String?,
        newPath: String?,
        completion: @escaping (FileHighlights) -> Void
    ) {
        queue.async { [self] in
            let pathForDetect = newPath ?? oldPath ?? ""
            let sniff = newBlob ?? oldBlob
            guard let binding = LanguageRegistry.binding(for: pathForDetect, contentSniff: sniff) else {
                DispatchQueue.main.async { completion(.empty) }
                return
            }

            let oldHL = highlightOne(blob: oldBlob, binding: binding)
            let newHL = highlightOne(blob: newBlob, binding: binding)

            let result = FileHighlights(oldSide: oldHL, newSide: newHL)
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Per-buffer

    private func highlightOne(blob: String?, binding: LanguageBinding) -> [Int: LineHighlights] {
        guard let blob, !blob.isEmpty else { return [:] }
        guard blob.utf8.count <= maxBlobBytes else { return [:] }
        guard let query = binding.highlightsQuery else { return [:] }

        let parser = Parser()
        do {
            try parser.setLanguage(binding.language)
        } catch {
            return [:]
        }
        guard let tree = parser.parse(blob) else { return [:] }
        guard let root = tree.rootNode else { return [:] }

        // Pre-compute UTF-16 offsets at the start of every line so we can convert global
        // capture ranges into per-line NSRange values.
        let lineStarts = computeLineStartUTF16Offsets(blob)

        let cursor = query.execute(node: root, in: tree)
        var captures: [QueryCapture] = []
        while let cap = cursor.nextCapture() {
            captures.append(cap)
        }

        var result: [Int: LineHighlights] = [:]
        for cap in captures {
            guard let name = cap.name else { continue }
            guard HighlightPalette.color(for: name) != nil else { continue }

            // tree-sitter Point.row is 0-based; column is byte offset within the row.
            // With UTF16LE encoding (Parser default), column is a UTF-16 byte offset → /2 → UTF-16 unit.
            let pointRange = cap.node.pointRange
            let startRow = Int(pointRange.lowerBound.row)
            let endRow = Int(pointRange.upperBound.row)

            // Multi-line captures (e.g. block comments, multi-line strings): split per line.
            if startRow == endRow {
                guard startRow >= 0, startRow < lineStarts.count else { continue }
                let lineStart = lineStarts[startRow]
                let nodeStart = Int(cap.node.range.location)
                let nodeEnd = nodeStart + cap.node.range.length
                let loc = nodeStart - lineStart
                let len = nodeEnd - nodeStart
                guard loc >= 0, len > 0 else { continue }
                appendToken(
                    HighlightToken(range: NSRange(location: loc, length: len), capture: name),
                    at: startRow + 1, // diff line numbers are 1-based
                    in: &result
                )
            } else {
                let nodeStart = Int(cap.node.range.location)
                let nodeEnd = nodeStart + cap.node.range.length
                for row in startRow ... endRow {
                    guard row >= 0, row < lineStarts.count else { continue }
                    let lineStart = lineStarts[row]
                    let lineEnd = (row + 1 < lineStarts.count)
                        ? lineStarts[row + 1] - 1 // exclude the newline
                        : nodeEnd
                    let segStart = max(nodeStart, lineStart)
                    let segEnd = min(nodeEnd, lineEnd)
                    let loc = segStart - lineStart
                    let len = segEnd - segStart
                    guard loc >= 0, len > 0 else { continue }
                    appendToken(
                        HighlightToken(range: NSRange(location: loc, length: len), capture: name),
                        at: row + 1,
                        in: &result
                    )
                }
            }
        }
        return result
    }

    private func appendToken(_ token: HighlightToken, at line: Int, in result: inout [Int: LineHighlights]) {
        if var lh = result[line] {
            lh.tokens.append(token)
            result[line] = lh
        } else {
            result[line] = LineHighlights(tokens: [token])
        }
    }

    /// Returns UTF-16 unit offsets at the start of each line.
    /// lineStarts[0] = 0, lineStarts[1] = offset just after first '\n', etc.
    private func computeLineStartUTF16Offsets(_ blob: String) -> [Int] {
        var offsets = [0]
        let utf16 = blob.utf16
        var idx = utf16.startIndex
        var pos = 0
        while idx < utf16.endIndex {
            if utf16[idx] == 0x000A { // '\n'
                offsets.append(pos + 1)
            }
            idx = utf16.index(after: idx)
            pos += 1
        }
        return offsets
    }
}
