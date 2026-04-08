import AppKit
import SwiftUI

struct WordDiffLineView: View {
    let segments: [WordDiffSegment]
    let lineBackground: Color
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                Text(segment.text)
                    .background(highlightColor(for: segment.kind))
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
    }

    private func highlightColor(for kind: WordDiffSegment.SegmentKind) -> Color {
        switch kind {
        case .equal: .clear
        case .added: Color.green.opacity(0.35)
        case .removed: Color.red.opacity(0.35)
        }
    }

    /// Builds an NSAttributedString with per-segment background colors for AppKit cell rendering.
    static func attributedString(segments: [WordDiffSegment], fontSize: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        for segment in segments {
            let attrs: [NSAttributedString.Key: Any] = switch segment.kind {
            case .equal:
                [
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]
            case .added:
                [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.35)
                ]
            case .removed:
                [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.systemRed.withAlphaComponent(0.35)
                ]
            }
            result.append(NSAttributedString(string: segment.text, attributes: attrs))
        }

        return result
    }
}
