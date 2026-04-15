import Foundation

/// Generates the workspace welcome screen — a TUI rendered in the terminal showing
/// the workspace's Pokémon banner with an interactive agent selector.
///
/// The ANSI banner (sprite + stats) is pre-rendered in Swift. The agent button row
/// and key loop are shell code so the highlight can update live. The result is a
/// `welcome()` shell function written to a per-workspace file and sourced by all
/// terminals in that workspace.
enum WorkspaceWelcomeScreen {

    /// Generate and write the `welcome` shell function for a workspace.
    /// Returns the file path, or nil if the workspace has no Pokémon entry.
    static func writeFunction(
        workspaceID: UUID,
        workspaceName: String,
        workspacePath: String,
        agents: [(name: String, command: String)]
    ) -> String? {
        guard let banner = renderBanner(pokemonName: workspaceName, workspacePath: workspacePath) else {
            return nil
        }
        let fn = generateShellFunction(bannerText: banner, agents: agents)
        return writeFile(fn, workspaceID: workspaceID)
    }

    // MARK: - Banner Rendering (ANSI)

    /// Returns raw terminal output text (with ANSI escape codes and Kitty image protocol)
    /// for the Pokémon welcome banner.
    private static func renderBanner(pokemonName: String, workspacePath: String) -> String? {
        guard let entry = PokemonDex.lookup(pokemonName) else { return nil }

        let esc = "\u{1B}"
        let reset = "\(esc)[0m"
        let bold = "\(esc)[1m"
        let dim = "\(esc)[2m"
        let color = ansiColor(for: entry.types.first ?? "Normal")

        let typeString = entry.types.joined(separator: " / ")
        let numberStr = String(format: "#%03d", entry.number)
        let shortPath = workspacePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")

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

        var output = "\r\n"

        if let imageData = PokemonDex.spriteData(for: entry.number) {
            let (imageColumns, imageRows) = estimateImageCells(imagePixels: 512)

            output += kittyImageSequence(data: imageData)
            output += "\(esc)[\(imageRows)A"

            let textPad = imageColumns + 2
            for line in infoLines {
                output += "\(esc)[\(textPad)C\(line)\r\n"
            }

            let remaining = imageRows - infoLines.count
            if remaining > 0 {
                output += "\(esc)[\(remaining)B"
            }
        } else {
            for line in infoLines {
                output += "  \(line)\r\n"
            }
        }

        output += "\r\n"
        return output
    }

    // MARK: - Shell Function Generation

    /// Generate the `welcome()` shell function with the banner baked in and an
    /// interactive agent selector (arrow keys, Enter, Esc).
    private static func generateShellFunction(
        bannerText: String,
        agents: [(name: String, command: String)]
    ) -> String {
        let bannerB64 = Data(bannerText.utf8).base64EncodedString()

        guard !agents.isEmpty else {
            return """
            welcome() {
                printf '\\033[2J\\033[H'
                printf '%s' "$(printf '%s' '\(bannerB64)' | base64 -d)"
            }
            """
        }

        let count = agents.count
        let namesArr = agents.map { "'\($0.name)'" }.joined(separator: " ")
        let cmdsArr = agents.map { "'\($0.command)'" }.joined(separator: " ")

        return """
        welcome() {
            local _esc=$'\\033'
            local _reset="${_esc}[0m"
            local _bold="${_esc}[1m"
            local _dim="${_esc}[2m"
            local _reverse="${_esc}[7m"
            local _hide_cursor="${_esc}[?25l"
            local _show_cursor="${_esc}[?25h"

            local -a _names=(\(namesArr))
            local -a _cmds=(\(cmdsArr))
            local _count=\(count)
            local _sel=1

            # Redraw just the button line in place (no scrolling)
            _welcome_draw_buttons() {
                printf '%s' "${_esc}[${_btn_row};1H${_esc}[K"
                local _i _btn _line="  "
                for _i in $(seq 1 $_count); do
                    _btn=" ${_names[$_i]} "
                    if [ "$_i" -eq "$_sel" ]; then
                        _line="${_line}${_reverse}${_bold}[${_btn}]${_reset}  "
                    else
                        _line="${_line}${_dim}[${_reset}${_btn}${_dim}]${_reset}  "
                    fi
                done
                printf '%s' "$_line"
            }

            # Clear screen, print banner
            printf '%s' "${_esc}[2J${_esc}[H${_hide_cursor}"
            printf '%s' "$(printf '%s' '\(bannerB64)' | base64 -d)"

            # Calculate button row from banner line count
            local _btn_row
            _btn_row=$(printf '%s' '\(bannerB64)' | base64 -d | tr -cd '\\n' | wc -c | tr -d ' ')
            _btn_row=$((_btn_row + 1))
            _welcome_draw_buttons
            # Print hint on the line below (fixed, never redrawn)
            printf '\\n\\n  %s← → navigate · enter select · esc shell%s' "$_dim" "$_reset"

            # Key loop
            local _old_stty _key _seq1 _seq2
            _old_stty=$(stty -g 2>/dev/null)
            stty -echo raw 2>/dev/null

            while true; do
                _key=""
                read -rs -k 1 _key 2>/dev/null < /dev/tty || \\
                    IFS= read -rs -n 1 _key 2>/dev/null < /dev/tty || true
                case "$_key" in
                    $'\\033')
                        _seq1=""
                        read -rs -t 0.1 -k 1 _seq1 2>/dev/null < /dev/tty || \\
                            IFS= read -rs -t 0.1 -n 1 _seq1 2>/dev/null < /dev/tty || true
                        if [ -z "$_seq1" ]; then
                            break
                        fi
                        _seq2=""
                        read -rs -t 0.1 -k 1 _seq2 2>/dev/null < /dev/tty || \\
                            IFS= read -rs -t 0.1 -n 1 _seq2 2>/dev/null < /dev/tty || true
                        case "${_seq1}${_seq2}" in
                            "[D")
                                if [ "$_sel" -gt 1 ]; then
                                    _sel=$((_sel - 1))
                                    _welcome_draw_buttons
                                fi
                                ;;
                            "[C")
                                if [ "$_sel" -lt "$_count" ]; then
                                    _sel=$((_sel + 1))
                                    _welcome_draw_buttons
                                fi
                                ;;
                            *)
                                ;;
                        esac
                        ;;
                    $'\\r'|$'\\n'|"")
                        stty "$_old_stty" 2>/dev/null
                        printf '%s%s' "$_show_cursor" "${_esc}[2J${_esc}[H"
                        forge terminal open-agent "${_cmds[$_sel]}" >/dev/null
                        exit
                        ;;
                    *)
                        ;;
                esac
            done

            stty "$_old_stty" 2>/dev/null
            printf '%s%s' "$_show_cursor" "${_esc}[2J${_esc}[H"
        }
        """
    }

    // MARK: - File I/O

    private static func writeFile(_ content: String, workspaceID: UUID) -> String {
        let dir = NSHomeDirectory() + "/\(ForgeStore.forgeDirName)/state/welcome"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(workspaceID.uuidString).sh")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Image Cell Estimation

    private static func estimateImageCells(imagePixels: Int) -> (columns: Int, rows: Int) {
        let config = TerminalAppearanceStore.shared.config
        let pointSize = Double(imagePixels) / 2.0
        let cellWidth = Double(config.fontSize) * 0.6
        let cellHeight = Double(config.fontSize) * Double(config.lineHeightMultiple)
        let columns = Int(ceil(pointSize / cellWidth))
        let rows = Int(ceil(pointSize / cellHeight))
        return (columns, rows)
    }

    // MARK: - Kitty Image Protocol

    private static func kittyImageSequence(data: Data) -> String {
        let base64 = data.base64EncodedString()
        let esc = "\u{1B}"
        let chunkSize = 4096
        var chunks: [String] = []
        var offset = base64.startIndex

        while offset < base64.endIndex {
            let end = base64.index(offset, offsetBy: chunkSize, limitedBy: base64.endIndex) ?? base64.endIndex
            chunks.append(String(base64[offset ..< end]))
            offset = end
        }

        var result = ""
        for (i, chunk) in chunks.enumerated() {
            let more = (i == chunks.count - 1) ? 0 : 1
            if i == 0 {
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
