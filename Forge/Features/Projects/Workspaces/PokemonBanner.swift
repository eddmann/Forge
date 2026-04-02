import Foundation

enum PokemonBanner {
    /// Returns raw terminal output text (with ANSI escape codes) for the Pokémon welcome banner.
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

        // Load sprite from bundled resources
        let sprite = PokemonDex.sprite(for: entry.number)

        var output = "\r\n"

        // Sprite on top
        if let sprite {
            output += sprite.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            if !sprite.hasSuffix("\n") { output += "\r\n" }
        }

        // Info below
        output += "\r\n"
        output += "  \(bold)\(color)\(numberStr) \(entry.name.uppercased())\(reset)\r\n"
        output += "  \(dim)Type: \(typeString)\(reset)\r\n"
        output += "  \(dim)─────────────────────────────\(reset)\r\n"
        output += "  \(dim)HP \(entry.hp)  ·  ATK \(entry.attack)  ·  DEF \(entry.defense)  ·  SPD \(entry.speed)\(reset)\r\n"
        output += "\r\n"

        let wrappedFlavor = wordWrap(entry.flavor, width: 50)
        for (i, line) in wrappedFlavor.enumerated() {
            let prefix = i == 0 ? "  \(dim)\"" : "   "
            let suffix = i == wrappedFlavor.count - 1 ? "\"\(reset)" : ""
            output += "\(prefix)\(line)\(suffix)\r\n"
        }

        output += "\r\n"
        output += "  \(dim)Workspace: \(shortPath)\(reset)\r\n"
        output += "  \(dim)Branch:    \(branch)\(reset)\r\n"
        output += "\r\n"

        return output
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
