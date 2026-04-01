import SwiftUI

struct TerminalAppearanceView: View {
    @ObservedObject private var store = TerminalAppearanceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Font section
            VStack(alignment: .leading, spacing: 6) {
                Text("Font")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(TerminalFont.allCases, id: \.self) { font in
                    fontRow(font)
                }
            }

            Divider()

            // Size section
            VStack(alignment: .leading, spacing: 6) {
                Text("Size")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    Button(action: { adjustSize(-1) }) {
                        Image(systemName: "minus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)

                    Text("\(Int(store.config.fontSize)) pt")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 40, alignment: .center)

                    Button(action: { adjustSize(1) }) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            // Line Height section
            VStack(alignment: .leading, spacing: 6) {
                Text("Line Height")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    Button(action: { adjustLineHeight(-0.1) }) {
                        Image(systemName: "minus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)

                    Text(String(format: "%.1f", store.config.lineHeightMultiple))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(width: 40, alignment: .center)

                    Button(action: { adjustLineHeight(0.1) }) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            // Theme section
            VStack(alignment: .leading, spacing: 6) {
                Text("Theme")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(TerminalTheme.allCases, id: \.self) { theme in
                    themeRow(theme)
                }
            }
        }
        .padding(14)
        .frame(width: 220)
    }

    private func fontRow(_ font: TerminalFont) -> some View {
        Button(action: { store.config.font = font }) {
            HStack {
                Image(systemName: store.config.font == font ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.config.font == font ? .accentColor : Color(nsColor: .tertiaryLabelColor))
                    .font(.system(size: 12))

                Text(font.displayName)
                    .font(.system(size: 12))

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func themeRow(_ theme: TerminalTheme) -> some View {
        Button(action: { store.config.theme = theme }) {
            HStack(spacing: 8) {
                Image(systemName: store.config.theme == theme ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(store.config.theme == theme ? .accentColor : Color(nsColor: .tertiaryLabelColor))
                    .font(.system(size: 12))

                // Color swatch
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: theme.background))
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                        )

                    // Show a few ANSI colors as dots
                    ForEach(Array(swatchColors(for: theme).enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 8, height: 8)
                    }
                }

                Text(theme.displayName)
                    .font(.system(size: 12))

                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func adjustSize(_ delta: CGFloat) {
        let newSize = store.config.fontSize + delta
        store.config.fontSize = min(max(newSize, 10), 24)
    }

    private func adjustLineHeight(_ delta: CGFloat) {
        let newValue = (store.config.lineHeightMultiple + delta)
        store.config.lineHeightMultiple = min(max((newValue * 10).rounded() / 10, 1.0), 2.0)
    }

    /// Pick a few representative ANSI colors for the swatch preview
    private func swatchColors(for theme: TerminalTheme) -> [NSColor] {
        let ansi = theme.ansiColors
        // red, green, blue, magenta (indices 1, 2, 4, 5)
        return [1, 2, 4, 5].map { ansi[$0] }
    }
}
