import Foundation

enum PokemonBanner {
    /// Returns raw terminal output text (with ANSI escape codes and Kitty image protocol)
    /// for the Pokémon welcome banner.
    /// Written directly to the terminal via `writeOutput`, so no command is visible.
    static func bannerText(pokemonName: String, workspacePath: String, branch: String) -> String? {
        guard let entry = PokemonDex.lookup(pokemonName) else { return nil }

        let esc = "\u{1B}"
        let reset = "\(esc)[0m"
        let bold = "\(esc)[1m"
        let dim = "\(esc)[2m"
        let color = ansiColor(for: entry.types.first ?? "Normal")

        let typeString = entry.types.joined(separator: " / ")
        let numberStr = String(format: "#%03d", entry.number)
        let shortPath = workspacePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        // Build info lines (without cursor positioning — we add that below)
        var infoLines: [String] = []
        infoLines.append("")
        infoLines.append("\(bold)\(color)\(numberStr) \(entry.name.uppercased())\(reset)")
        infoLines.append("\(dim)Type: \(typeString)\(reset)")
        infoLines.append("\(dim)─────────────────────────────\(reset)")
        infoLines.append(
            "\(dim)HP \(entry.hp)  ·  ATK \(entry.attack)  ·  DEF \(entry.defense)  ·  SPD \(entry.speed)\(reset)"
        )
        infoLines.append("")

        let wrappedFlavor = wordWrap(entry.flavor, width: 40)
        for (i, line) in wrappedFlavor.enumerated() {
            let prefix = i == 0 ? "\(dim)\"" : " "
            let suffix = i == wrappedFlavor.count - 1 ? "\"\(reset)" : ""
            infoLines.append("\(prefix)\(line)\(suffix)")
        }

        infoLines.append("")
        infoLines.append("\(dim)Workspace: \(shortPath)\(reset)")
        infoLines.append("\(dim)Branch:    \(branch)\(reset)")

        var output = "\r\n"

        // Sprite via Kitty image protocol, with text alongside
        if let imageData = PokemonDex.spriteData(for: entry.number) {
            let (imageColumns, imageRows) = estimateImageCells(imagePixels: 512)

            output += kittyImageSequence(data: imageData)

            // Cursor up to the top of the image, then print text lines alongside
            output += "\(esc)[\(imageRows)A"

            let textPad = imageColumns + 2
            for line in infoLines {
                output += "\(esc)[\(textPad)C\(line)\r\n"
            }

            // Move cursor below the image if text was shorter
            let remaining = imageRows - infoLines.count
            if remaining > 0 {
                output += "\(esc)[\(remaining)B"
            }
        } else {
            // Fallback: text only
            for line in infoLines {
                output += "  \(line)\r\n"
            }
        }

        output += "\r\n"
        return output
    }

    // MARK: - Image Cell Estimation

    /// Estimate how many terminal columns and rows a square image occupies.
    /// On Retina (2×), 512 image pixels = 256 points.
    /// Cell width ≈ fontSize × 0.6, cell height ≈ fontSize × lineHeightMultiple.
    private static func estimateImageCells(imagePixels: Int) -> (columns: Int, rows: Int) {
        let config = TerminalAppearanceStore.shared.config
        let pointSize = Double(imagePixels) / 2.0 // Retina 2×
        let cellWidth = Double(config.fontSize) * 0.6
        let cellHeight = Double(config.fontSize) * Double(config.lineHeightMultiple)
        let columns = Int(ceil(pointSize / cellWidth))
        let rows = Int(ceil(pointSize / cellHeight))
        return (columns, rows)
    }

    // MARK: - Kitty Image Protocol

    /// Encode PNG data as a Kitty graphics protocol escape sequence.
    /// Uses direct transmission (a=T) with PNG format (f=100).
    private static func kittyImageSequence(data: Data) -> String {
        let base64 = data.base64EncodedString()
        let esc = "\u{1B}"

        // Kitty protocol sends in chunks of up to 4096 base64 chars.
        let chunkSize = 4096
        var chunks: [String] = []
        var offset = base64.startIndex

        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            let chunk = String(base64[offset ..< end])
            chunks.append(chunk)
            offset = end
        }

        var result = ""
        for (i, chunk) in chunks.enumerated() {
            let isFirst = i == 0
            let isLast = i == chunks.count - 1
            let more = isLast ? 0 : 1

            if isFirst {
                result += "\(esc)_Gf=100,a=T,m=\(more);\(chunk)\(esc)\\"
            } else {
                result += "\(esc)_Gm=\(more);\(chunk)\(esc)\\"
            }
        }

        return result
    }

    // MARK: - Type → ANSI Color

    private static func ansiColor(for type: String) -> String {
        let esc = "\u{1B}"
        switch type {
        case "Fire": return "\(esc)[31m"
        case "Water": return "\(esc)[34m"
        case "Grass": return "\(esc)[32m"
        case "Electric": return "\(esc)[33m"
        case "Ice": return "\(esc)[36m"
        case "Fighting": return "\(esc)[31m"
        case "Poison": return "\(esc)[35m"
        case "Ground": return "\(esc)[33m"
        case "Flying": return "\(esc)[36m"
        case "Psychic": return "\(esc)[35m"
        case "Bug": return "\(esc)[32m"
        case "Rock": return "\(esc)[33m"
        case "Ghost": return "\(esc)[35m"
        case "Dragon": return "\(esc)[34m"
        case "Dark": return "\(esc)[90m"
        case "Steel": return "\(esc)[37m"
        case "Fairy": return "\(esc)[95m"
        default: return "\(esc)[37m"
        }
    }

    // MARK: - Helpers

    private static func wordWrap(_ text: String, width: Int) -> [String] {
        let words = text.split(separator: " ")
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
