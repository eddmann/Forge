import AppKit

/// Maps tree-sitter highlight capture names to colors. Foreground only — never bold/italic
/// or font swaps, since the diff view's selection geometry assumes a fixed monospaced glyph
/// width (see DiffTableView.charWidth).
enum HighlightPalette {
    static func color(for capture: String) -> NSColor? {
        // Try the full capture name first for specificity, then fall back to the base segment.
        if let exact = colors[capture] { return exact }
        if let dot = capture.firstIndex(of: ".") {
            let base = String(capture[..<dot])
            if let fallback = colors[base] { return fallback }
        }
        return nil
    }

    // swiftlint:disable:next identifier_name
    private static let colors: [String: NSColor] = [
        // Keywords (+ CSS at-rules that act as keywords)
        "keyword": .systemPink,
        "import": .systemPink,
        "charset": .systemPink,
        "keyframes": .systemPink,
        "media": .systemPink,
        "supports": .systemPink,

        // Strings & escape sequences
        "string": .systemRed,
        "string.special": .systemRed,
        "string.escape": .systemBrown,
        "string.regexp": .systemBrown,
        "character": .systemBrown,
        "escape": .systemBrown,
        "regex": .systemBrown,

        // Comments
        "comment": .secondaryLabelColor,

        // Literals
        "number": .systemOrange,
        "boolean": .systemOrange,
        "constant": .systemOrange,
        "constant.builtin": .systemOrange,

        // Functions / methods
        "function": .systemBlue,
        "function.builtin": .systemCyan,
        "function.method": .systemBlue,
        "method": .systemBlue,
        "constructor": .systemYellow,

        // Types / classes / modules
        "type": .systemTeal,
        "type.builtin": .systemTeal,
        "class": .systemTeal,
        "interface": .systemTeal,
        "namespace": .systemTeal,
        "module": .systemTeal,
        "module.builtin": .systemTeal,

        // Variables / properties
        "variable": .labelColor,
        "variable.builtin": .systemPink,
        "parameter": .labelColor,
        "property": .systemPurple,
        "field": .systemPurple,

        // Operators / punctuation
        "operator": .secondaryLabelColor,
        "punctuation": .tertiaryLabelColor,

        // Markup / tags
        "tag": .systemBlue,
        "attribute": .systemIndigo,
        "label": .systemTeal,

        // Markdown text
        "text.title": .systemBlue,
        "text.strong": .labelColor,
        "text.emphasis": .labelColor,
        "text.literal": .systemRed,
        "text.uri": .systemCyan,
        "text.reference": .systemPurple,

        // Embedded code (JS/Python/Bash)
        "embedded": .labelColor
    ]
}
