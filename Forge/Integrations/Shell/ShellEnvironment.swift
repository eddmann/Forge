import Foundation

enum ShellEnvironment {
    /// User's full PATH resolved from their login shell (cached once at launch)
    static let resolvedPath: String = {
        let shell = defaultShell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            {
                return path
            }
        } catch {}
        return "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    /// The user's default shell path
    static var defaultShell: String {
        // Try $SHELL first
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }

        // Fall back to getpwuid
        if let pw = getpwuid(getuid()), let shellCStr = pw.pointee.pw_shell {
            return String(cString: shellCStr)
        }

        // Ultimate fallback
        return "/bin/zsh"
    }

    // MARK: - Shell Integration (ZDOTDIR injection)

    /// Directory where Forge writes its ZDOTDIR wrapper and integration scripts.
    static let shellIntegrationDir: String = {
        let dir = NSHomeDirectory() + "/.forge/state/shell"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Shell integration sourced by both zsh and bash.
    /// Uses a zsh precmd hook / bash PROMPT_COMMAND to apply settings
    /// after ALL user dotfiles have loaded.
    private static let shellIntegrationScript = """
    # Scrollback restore (runs immediately)
    _forge_restore_scrollback_once() {
        local path="${FORGE_RESTORE_SCROLLBACK_FILE:-}"
        [[ -n "$path" ]] || return 0
        unset FORGE_RESTORE_SCROLLBACK_FILE
        if [[ -r "$path" ]]; then
            /bin/cat -- "$path" 2>/dev/null || true
            /bin/rm -f -- "$path" >/dev/null 2>&1 || true
        fi
    }
    _forge_restore_scrollback_once

    # Per-session history: apply via precmd so it runs after .zshrc/.bashrc
    _forge_apply_histfile() {
        if [[ -n "${FORGE_HISTFILE:-}" ]]; then
            export HISTFILE="$FORGE_HISTFILE"
            unset FORGE_HISTFILE
            # Reload history from the new file
            if [[ -n "${ZSH_VERSION:-}" ]]; then
                fc -p "$HISTFILE"
            fi
        fi
        # Self-remove: only need to run once
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            precmd_functions=(${precmd_functions:#_forge_apply_histfile})
        fi
    }
    if [[ -n "${FORGE_HISTFILE:-}" ]]; then
        if [[ -n "${ZSH_VERSION:-}" ]]; then
            precmd_functions+=(_forge_apply_histfile)
        else
            _forge_apply_histfile
        fi
    fi
    """

    /// Write ZDOTDIR wrapper + integration scripts to ~/.forge/state/shell/
    /// Uses the ZDOTDIR trick: set ZDOTDIR to our dir so zsh loads our .zshenv,
    /// which restores the real ZDOTDIR and sources our integration automatically.
    static func ensureShellIntegration() {
        let dir = shellIntegrationDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // .zshenv — ZDOTDIR bootstrap: restore real ZDOTDIR, source user's .zshenv,
        // then load Forge integration on interactive shells
        let zshenv = """
        # Forge ZDOTDIR bootstrap for zsh
        # Restore the user's real ZDOTDIR immediately
        if [[ -n "${FORGE_ZSH_ZDOTDIR+X}" ]]; then
            builtin export ZDOTDIR="$FORGE_ZSH_ZDOTDIR"
            builtin unset FORGE_ZSH_ZDOTDIR
        else
            builtin unset ZDOTDIR
        fi

        # Source the user's real .zshenv
        {
            builtin typeset _forge_file="${ZDOTDIR-$HOME}/.zshenv"
            [[ ! -r "$_forge_file" ]] || builtin source -- "$_forge_file"
        } always {
            if [[ -o interactive ]]; then
                # Load Forge shell integration
                if [[ -n "${FORGE_SHELL_INTEGRATION_DIR:-}" ]]; then
                    builtin typeset _forge_integ="$FORGE_SHELL_INTEGRATION_DIR/forge-zsh-integration.zsh"
                    [[ -r "$_forge_integ" ]] && builtin source -- "$_forge_integ"
                fi
            fi
            builtin unset _forge_file _forge_integ
        }
        """
        try? zshenv.write(toFile: (dir as NSString).appendingPathComponent(".zshenv"),
                          atomically: true, encoding: .utf8)

        // .zshrc — fallback shim (shouldn't normally be reached since .zshenv restores ZDOTDIR)
        let zshrc = """
        # Forge fallback .zshrc — restore ZDOTDIR and source user's .zshrc
        if [[ -n "${FORGE_ZSH_ZDOTDIR+X}" ]]; then
            builtin export ZDOTDIR="$FORGE_ZSH_ZDOTDIR"
            builtin unset FORGE_ZSH_ZDOTDIR
        else
            builtin unset ZDOTDIR
        fi
        builtin typeset _forge_file="${ZDOTDIR-$HOME}/.zshrc"
        [[ ! -r "$_forge_file" ]] || builtin source -- "$_forge_file"
        builtin unset _forge_file
        """
        try? zshrc.write(toFile: (dir as NSString).appendingPathComponent(".zshrc"),
                         atomically: true, encoding: .utf8)

        // .zprofile — chain to user's .zprofile
        let zprofile = """
        builtin typeset _forge_file="${ZDOTDIR-$HOME}/.zprofile"
        [[ ! -r "$_forge_file" ]] || builtin source -- "$_forge_file"
        builtin unset _forge_file
        """
        try? zprofile.write(toFile: (dir as NSString).appendingPathComponent(".zprofile"),
                            atomically: true, encoding: .utf8)

        // .zlogin — chain to user's .zlogin
        let zlogin = """
        builtin typeset _forge_file="${ZDOTDIR-$HOME}/.zlogin"
        [[ ! -r "$_forge_file" ]] || builtin source -- "$_forge_file"
        builtin unset _forge_file
        """
        try? zlogin.write(toFile: (dir as NSString).appendingPathComponent(".zlogin"),
                          atomically: true, encoding: .utf8)

        // forge-zsh-integration.zsh — the actual integration script
        try? shellIntegrationScript.write(
            toFile: (dir as NSString).appendingPathComponent("forge-zsh-integration.zsh"),
            atomically: true, encoding: .utf8
        )

        // forge-bash-integration.bash — bash variant
        try? shellIntegrationScript.write(
            toFile: (dir as NSString).appendingPathComponent("forge-bash-integration.bash"),
            atomically: true, encoding: .utf8
        )
    }

    /// Build environment variables for terminal sessions
    static func buildEnvironment(sessionID: UUID? = nil) -> [String: String] {
        // Standard terminal environment variables
        var env: [String: String] = [
            "TERM": "xterm-ghostty",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "ghostty"
        ]

        // Use the resolved login shell PATH (GUI apps don't inherit shell PATH)
        env["PATH"] = resolvedPath

        // HOME
        env["HOME"] = NSHomeDirectory()

        // LANG for proper encoding
        if let lang = ProcessInfo.processInfo.environment["LANG"] {
            env["LANG"] = lang
        } else {
            env["LANG"] = "en_US.UTF-8"
        }

        // SHELL
        let shell = defaultShell
        env["SHELL"] = shell

        // Forge socket for agent communication
        env["FORGE_SOCKET"] = ForgeStore.shared.stateDir
            .appendingPathComponent("forge.sock").path

        // OpenCode: register forge-bridge plugin via config content
        let pluginPath = NSHomeDirectory() + "/.config/opencode/plugin/forge-bridge.ts"
        env["OPENCODE_CONFIG_CONTENT"] = "{\"plugin\":[\"\(pluginPath)\"]}"

        if let sessionID {
            env["FORGE_SESSION"] = sessionID.uuidString

            // Per-session shell history — stored in env, applied by shell integration after user's rc files
            let historyDir = (NSHomeDirectory() as NSString).appendingPathComponent(".forge/state/history")
            try? FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
            env["FORGE_HISTFILE"] = (historyDir as NSString).appendingPathComponent("\(sessionID.uuidString)")
        }

        // Shell integration via ZDOTDIR injection (zsh) or PROMPT_COMMAND (bash)
        let integrationDir = shellIntegrationDir
        env["FORGE_SHELL_INTEGRATION_DIR"] = integrationDir

        let shellName = (shell as NSString).lastPathComponent
        if shellName == "zsh" {
            // Save user's real ZDOTDIR so our .zshenv can restore it
            if let existingZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"],
               !existingZdotdir.isEmpty
            {
                env["FORGE_ZSH_ZDOTDIR"] = existingZdotdir
            }
            env["ZDOTDIR"] = integrationDir
        } else if shellName == "bash" {
            // Bash: use PROMPT_COMMAND to source integration on first prompt
            env["PROMPT_COMMAND"] = """
            unset PROMPT_COMMAND; \
            if [[ -n "${FORGE_SHELL_INTEGRATION_DIR:-}" ]]; then \
            _forge_bash="$FORGE_SHELL_INTEGRATION_DIR/forge-bash-integration.bash"; \
            [[ -r "$_forge_bash" ]] && source "$_forge_bash"; \
            unset _forge_bash; \
            fi
            """
        }

        return env
    }
}
