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
}
