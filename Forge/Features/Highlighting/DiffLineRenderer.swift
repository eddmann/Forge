import AppKit

/// Builds the NSAttributedString for a single diff line, layering syntax highlight foreground
/// colors and word-diff background colors over a monospaced base. Color-only attributes —
/// never bold/italic — so the table view's fixed-width selection geometry stays valid.
enum DiffLineRenderer {
    static func attributedString(
        text: String,
        font: NSFont,
        tokens: [HighlightToken],
        wordDiffs: [WordDiffSegment]?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        let length = (text as NSString).length

        for token in tokens {
            guard let color = HighlightPalette.color(for: token.capture) else { continue }
            let clipped = clip(token.range, max: length)
            guard clipped.length > 0 else { continue }
            result.addAttribute(.foregroundColor, value: color, range: clipped)
        }

        if let wordDiffs {
            var location = 0
            for segment in wordDiffs {
                let segLen = (segment.text as NSString).length
                defer { location += segLen }
                guard segment.kind != .equal else { continue }
                let bg: NSColor = segment.kind == .added
                    ? NSColor.systemGreen.withAlphaComponent(0.35)
                    : NSColor.systemRed.withAlphaComponent(0.35)
                let range = clip(NSRange(location: location, length: segLen), max: length)
                guard range.length > 0 else { continue }
                result.addAttribute(.backgroundColor, value: bg, range: range)
            }
        }

        return result
    }

    private static func clip(_ range: NSRange, max length: Int) -> NSRange {
        let start = min(max(0, range.location), length)
        let end = min(max(0, range.location + range.length), length)
        return NSRange(location: start, length: max(0, end - start))
    }
}
