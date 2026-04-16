import AppKit

/// Maps tree-sitter highlight capture names to colors. Foreground only — never bold/italic
/// or font swaps, since the diff view's selection geometry assumes a fixed monospaced glyph
/// width (see DiffTableView.charWidth).
enum HighlightPalette {
    static func color(for capture: String) -> NSColor? {
        switch firstSegment(of: capture) {
        case "keyword":
            NSColor.systemPink
        case "string", "string.special":
            NSColor.systemRed
        case "comment":
            NSColor.secondaryLabelColor
        case "number":
            NSColor.systemOrange
        case "function", "method":
            NSColor.systemPurple
        case "type", "class", "interface", "namespace":
            NSColor.systemTeal
        case "constant":
            NSColor.systemBrown
        case "variable", "parameter", "property", "field":
            NSColor.labelColor
        case "operator":
            NSColor.secondaryLabelColor
        case "punctuation":
            NSColor.tertiaryLabelColor
        case "tag":
            NSColor.systemBlue
        case "attribute":
            NSColor.systemIndigo
        case "label":
            NSColor.systemTeal
        case "boolean":
            NSColor.systemOrange
        case "escape", "regex":
            NSColor.systemBrown
        default:
            nil
        }
    }

    private static func firstSegment(of capture: String) -> String {
        if let dot = capture.firstIndex(of: ".") {
            return String(capture[..<dot])
        }
        return capture
    }
}
