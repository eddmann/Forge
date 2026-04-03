import AppKit

// MARK: - Terminal Font

enum TerminalFont: String, Codable, CaseIterable {
    case sfMono
    case jetBrainsMono
    case firaCode

    var displayName: String {
        switch self {
        case .sfMono: "SF Mono"
        case .jetBrainsMono: "JetBrains Mono"
        case .firaCode: "Fira Code"
        }
    }

    var fontName: String {
        switch self {
        case .sfMono: "SF Mono"
        case .jetBrainsMono: "JetBrains Mono"
        case .firaCode: "Fira Code"
        }
    }

    func nsFont(size: CGFloat) -> NSFont {
        NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Terminal Theme

enum TerminalTheme: String, Codable, CaseIterable {
    case dark
    case light

    var displayName: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var isDark: Bool {
        switch self {
        case .dark: true
        case .light: false
        }
    }

    var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    // MARK: - App Chrome Colors

    /// Window bg: the base behind everything
    var windowBackground: NSColor {
        switch self {
        case .dark: NSColor(white: 0.08, alpha: 0.92)
        case .light: NSColor(white: 0.84, alpha: 0.92) // Xcode-style gray, transparent like dark
        }
    }

    /// Tab bar / status bar bg — distinct from content area
    var chromeBackground: NSColor {
        switch self {
        case .dark: NSColor(white: 0.14, alpha: 1.0) // +0.06 from terminal
        case .light: NSColor(white: 0.84, alpha: 1.0) // Xcode tab bar gray, opaque
        }
    }

    /// Active tab — flush with terminal content
    var chromeActiveBackground: NSColor {
        switch self {
        case .dark: NSColor(white: 0.20, alpha: 1.0)
        case .light: NSColor(white: 0.98, alpha: 1.0) // near-white, flush with terminal
        }
    }

    /// Hovered tab — between chrome and active
    var chromeHoverBackground: NSColor {
        switch self {
        case .dark: NSColor(white: 0.17, alpha: 1.0)
        case .light: NSColor(white: 0.88, alpha: 1.0)
        }
    }

    /// Primary text: high contrast
    var chromePrimaryText: NSColor {
        switch self {
        case .dark: NSColor(white: 0.95, alpha: 1.0)
        case .light: NSColor(white: 0.10, alpha: 1.0)
        }
    }

    /// Secondary text: medium contrast
    var chromeSecondaryText: NSColor {
        switch self {
        case .dark: NSColor(white: 0.55, alpha: 1.0)
        case .light: NSColor(white: 0.50, alpha: 1.0)
        }
    }

    /// Borders and separators
    var chromeBorder: NSColor {
        switch self {
        case .dark: NSColor(white: 1.0, alpha: 0.08)
        case .light: NSColor(white: 0.0, alpha: 0.15)
        }
    }

    /// Accent color
    var accent: NSColor {
        switch self {
        case .dark: NSColor(red: 1.0, green: 0.76, blue: 0.28, alpha: 1.0)
        case .light: hex(0x0069D9) // Xcode blue
        }
    }

    /// Command palette / popover bg
    var popoverBackground: NSColor {
        switch self {
        case .dark: NSColor(white: 0.11, alpha: 0.98)
        case .light: NSColor(white: 0.94, alpha: 0.98)
        }
    }

    // MARK: - Terminal Colors

    var foreground: NSColor {
        switch self {
        case .dark: NSColor(white: 0.9, alpha: 1.0)
        case .light: hex(0x262626)
        }
    }

    var background: NSColor {
        switch self {
        case .dark: NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        case .light: NSColor(white: 1.0, alpha: 1.0)
        }
    }

    var cursor: NSColor {
        accent
    }

    var cursorText: NSColor {
        switch self {
        case .dark: NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        case .light: NSColor(white: 1.0, alpha: 1.0)
        }
    }

    var selectionBackground: NSColor {
        switch self {
        case .dark: NSColor(white: 0.3, alpha: 1.0)
        case .light: hex(0xB4D8FD)
        }
    }

    var selectionForeground: NSColor {
        switch self {
        case .dark: NSColor(white: 1.0, alpha: 1.0)
        case .light: hex(0x262626)
        }
    }

    /// 16-color ANSI palette — Xcode-style for light, standard for dark.
    var ansiColorTuples: [(r: UInt8, g: UInt8, b: UInt8)] {
        switch self {
        case .dark:
            rgbTuples(
                (0x00, 0x00, 0x00), (0xCC, 0x33, 0x33), (0x33, 0xB3, 0x33), (0xCC, 0xB3, 0x33),
                (0x4D, 0x80, 0xCC), (0xB3, 0x4D, 0xB3), (0x33, 0xB3, 0xB3), (0xBF, 0xBF, 0xBF),
                (0x66, 0x66, 0x66), (0xFF, 0x4D, 0x4D), (0x4D, 0xFF, 0x4D), (0xFF, 0xFF, 0x4D),
                (0x66, 0x99, 0xFF), (0xFF, 0x66, 0xFF), (0x4D, 0xFF, 0xFF), (0xFF, 0xFF, 0xFF)
            )
        case .light:
            rgbTuples(
                (0x00, 0x00, 0x00), (0xC4, 0x1A, 0x16), (0x00, 0x7D, 0x27), (0x82, 0x6B, 0x28),
                (0x00, 0x69, 0xD9), (0x9C, 0x27, 0xB0), (0x31, 0x7B, 0x7D), (0x26, 0x26, 0x26),
                (0x8E, 0x8E, 0x93), (0xC4, 0x1A, 0x16), (0x00, 0x7D, 0x27), (0x82, 0x6B, 0x28),
                (0x00, 0x69, 0xD9), (0x9C, 0x27, 0xB0), (0x31, 0x7B, 0x7D), (0x00, 0x00, 0x00)
            )
        }
    }

    /// 16-color ANSI palette as NSColors
    var ansiColors: [NSColor] {
        ansiColorTuples.map { NSColor(
            red: CGFloat($0.r) / 255.0,
            green: CGFloat($0.g) / 255.0,
            blue: CGFloat($0.b) / 255.0,
            alpha: 1.0
        ) }
    }

    /// Preview colors for the theme picker swatch
    var previewColors: [NSColor] {
        [background, foreground, cursor]
    }
}

// MARK: - Helpers

private func hex(_ value: Int) -> NSColor {
    NSColor(
        red: CGFloat((value >> 16) & 0xFF) / 255.0,
        green: CGFloat((value >> 8) & 0xFF) / 255.0,
        blue: CGFloat(value & 0xFF) / 255.0,
        alpha: 1.0
    )
}

private func rgbTuples(_ colors: (UInt8, UInt8, UInt8)...) -> [(r: UInt8, g: UInt8, b: UInt8)] {
    colors.map { (r: $0.0, g: $0.1, b: $0.2) }
}

// MARK: - Config

enum CursorStyle: String, Codable, CaseIterable {
    case block
    case bar
    case underline

    var displayName: String {
        switch self {
        case .block: "Block"
        case .bar: "Bar"
        case .underline: "Underline"
        }
    }

    var ghosttyValue: String {
        rawValue
    }
}

struct TerminalAppearanceConfig: Equatable {
    var font: TerminalFont = .firaCode
    var fontSize: CGFloat = 16
    var lineHeightMultiple: CGFloat = 1.4
    var theme: TerminalTheme = .dark
    var cursorStyle: CursorStyle = .block
    var cursorBlink: Bool = false
    var scrollbackLines: Int = 50000
    var diffFontSize: Double = 16

    private enum CodingKeys: String, CodingKey {
        case font, fontSize, theme, cursorStyle, cursorBlink, diffFontSize
        case lineHeightMultiple = "lineHeight"
        case scrollbackLines = "scrollback"
    }
}

extension TerminalAppearanceConfig: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = (try? c.decode(TerminalFont.self, forKey: .font)) ?? .firaCode
        fontSize = (try? c.decode(CGFloat.self, forKey: .fontSize)) ?? 16
        lineHeightMultiple = (try? c.decode(CGFloat.self, forKey: .lineHeightMultiple)) ?? 1.4
        // Gracefully handle removed themes (dracula, oneDark, nord) by falling back to .dark
        theme = (try? c.decode(TerminalTheme.self, forKey: .theme)) ?? .dark
        cursorStyle = (try? c.decode(CursorStyle.self, forKey: .cursorStyle)) ?? .block
        cursorBlink = (try? c.decode(Bool.self, forKey: .cursorBlink)) ?? false
        scrollbackLines = (try? c.decode(Int.self, forKey: .scrollbackLines)) ?? 50000
        diffFontSize = (try? c.decode(Double.self, forKey: .diffFontSize)) ?? 16
    }
}
