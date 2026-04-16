import Foundation

struct HighlightToken: Hashable {
    var range: NSRange
    var capture: String
}

struct LineHighlights: Hashable {
    var tokens: [HighlightToken]
}

struct FileHighlights: Hashable {
    var oldSide: [Int: LineHighlights]
    var newSide: [Int: LineHighlights]

    static let empty = FileHighlights(oldSide: [:], newSide: [:])

    var isEmpty: Bool {
        oldSide.isEmpty && newSide.isEmpty
    }
}
