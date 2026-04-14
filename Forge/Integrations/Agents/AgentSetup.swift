import Foundation

/// Installs per-agent hooks, config files, and extensions on app startup.
/// Each agent gets its native integration mechanism — no uniform approach.
class AgentSetup {
    static let shared = AgentSetup()

    /// Marker comment used to identify Forge-managed hook entries.
    static let forgeMarker = "forge event"

    /// Shared installer used by every agent that ships standard JSON hook settings
    /// (Claude Code, Codex). Pi/OpenCode use TypeScript bridge files instead.
    private static let installer = AgentHookInstaller(ownershipMarker: forgeMarker)

    private init() {}

    /// Install hooks/config/extensions for all known agents.
    func installAll() {
        installClaudeCodeHooks()
        installCodexHooks()
        installPiExtension()
        installOpenCodePlugin()
        trustClaudeCodeClonesDir()
    }

    // MARK: - Public Inspection / Removal

    /// Whether Forge-managed hooks are currently present in Claude Code's settings.
    func hasClaudeCodeHooks() -> Bool {
        Self.installer.isInstalled(settingsURL: claudeSettingsURL)
    }

    /// Whether Forge-managed hooks are currently present in Codex's hooks file.
    func hasCodexHooks() -> Bool {
        Self.installer.isInstalled(settingsURL: codexHooksURL)
    }

    /// Remove Forge-managed hooks from Claude Code's settings, preserving user hooks.
    func removeClaudeCodeHooks() throws {
        try Self.installer.uninstall(settingsURL: claudeSettingsURL)
    }

    /// Remove Forge-managed hooks from Codex's settings, preserving user hooks.
    func removeCodexHooks() throws {
        try Self.installer.uninstall(settingsURL: codexHooksURL)
    }

    /// Public, throwing install for the Settings UI. Unlike the silent boot-time
    /// install, this surfaces errors so the user can act on them.
    func installClaudeCodeHooksThrowing() throws {
        try Self.installer.install(settingsURL: claudeSettingsURL, hooks: Self.claudeHookGroups)
    }

    func installCodexHooksThrowing() throws {
        try Self.installer.install(settingsURL: codexHooksURL, hooks: Self.codexHookGroups)
    }

    // MARK: - Claude Code

    private var claudeSettingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
    }

    /// Build hook entries — guarded by FORGE_SESSION so hooks only fire inside Forge.
    /// Uses if/then/fi (not &&) so exit code is always 0 when outside Forge.
    private static func claudeHook(_ event: String) -> String {
        "if [ -n \"$FORGE_SESSION\" ]; then forge event claude \(event); fi"
    }

    /// Hook groups for Claude Code, keyed by event name.
    private static let claudeHookGroups: [String: [[String: Any]]] = [
        "SessionStart": [
            ["hooks": [["type": "command", "command": claudeHook("session_start")]]]
        ],
        "PreToolUse": [
            ["hooks": [["type": "command", "command": claudeHook("tool_start")]]]
        ],
        "PostToolUse": [
            ["hooks": [["type": "command", "command": claudeHook("tool_end")]]]
        ],
        "Stop": [
            ["hooks": [["type": "command", "command": claudeHook("stop")]]]
        ],
        "UserPromptSubmit": [
            ["hooks": [["type": "command", "command": claudeHook("prompt")]]]
        ],
        "Notification": [
            ["matcher": "permission_prompt|elicitation_dialog",
             "hooks": [["type": "command", "command": claudeHook("notification")]]]
        ]
    ]

    /// Writes hooks to ~/.claude/settings.json (only if ~/.claude/ exists)
    private func installClaudeCodeHooks() {
        let dir = claudeSettingsURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try? Self.installer.install(settingsURL: claudeSettingsURL, hooks: Self.claudeHookGroups)
    }

    // MARK: - Codex

    private var codexHooksURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.codex/hooks.json")
    }

    private static func codexHook(_ event: String) -> String {
        "if [ -n \"$FORGE_SESSION\" ]; then forge event codex \(event); fi"
    }

    /// Hook groups for Codex, keyed by event name.
    private static let codexHookGroups: [String: [[String: Any]]] = [
        "SessionStart": [
            ["hooks": [["type": "command", "command": codexHook("session_start")]]]
        ],
        "PreToolUse": [
            ["hooks": [["type": "command", "command": codexHook("tool_start")]]]
        ],
        "PostToolUse": [
            ["hooks": [["type": "command", "command": codexHook("tool_end")]]]
        ],
        "UserPromptSubmit": [
            ["hooks": [["type": "command", "command": codexHook("prompt")]]]
        ],
        "Stop": [
            ["hooks": [["type": "command", "command": codexHook("stop")]]]
        ]
    ]

    /// Writes hooks to ~/.codex/hooks.json and TUI config to ~/.codex/config.toml (only if ~/.codex/ exists)
    private func installCodexHooks() {
        let codexDir = NSHomeDirectory() + "/.codex"
        let fm = FileManager.default

        // Only install if Codex is already set up
        guard fm.fileExists(atPath: codexDir) else { return }

        try? Self.installer.install(settingsURL: codexHooksURL, hooks: Self.codexHookGroups)

        // config.toml — enrich terminal title with status word and enable hooks
        let configPath = codexDir + "/config.toml"
        var configLines: [String] = []
        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            configLines = existing.components(separatedBy: "\n")
        }

        var configChanged = false

        // Check if [tui] section with terminal_title already exists
        let hasTuiTitle = configLines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("terminal_title") }
        if !hasTuiTitle {
            let hasTuiSection = configLines.contains { $0.trimmingCharacters(in: .whitespaces) == "[tui]" }
            if !hasTuiSection {
                configLines.append("")
                configLines.append("[tui]")
            }
            if let tuiIndex = configLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[tui]" }) {
                configLines.insert("terminal_title = [\"spinner\", \"status\", \"project\"]", at: tuiIndex + 1)
            }
            configChanged = true
        }

        // Enable codex_hooks feature flag so hooks.json is honoured
        let hasHooksFlag = configLines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("codex_hooks") }
        if !hasHooksFlag {
            let hasFeaturesSection = configLines.contains { $0.trimmingCharacters(in: .whitespaces) == "[features]" }
            if !hasFeaturesSection {
                configLines.append("")
                configLines.append("[features]")
            }
            if let featIdx = configLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
                configLines.insert("codex_hooks = true", at: featIdx + 1)
            }
            configChanged = true
        }

        if configChanged {
            try? configLines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Pi

    /// Drops forge-bridge.ts extension into ~/.pi/agent/extensions/ (only if ~/.pi/agent/ exists)
    private func installPiExtension() {
        let piAgentDir = NSHomeDirectory() + "/.pi/agent"
        let extensionDir = piAgentDir + "/extensions"
        let extensionPath = extensionDir + "/forge-bridge.ts"
        let fm = FileManager.default

        // Only install if Pi is already set up
        guard fm.fileExists(atPath: piAgentDir) else { return }

        if !fm.fileExists(atPath: extensionDir) {
            try? fm.createDirectory(atPath: extensionDir, withIntermediateDirectories: true)
        }

        let extensionCode = """
        import * as net from "node:net";

        export default function(pi: any) {
          const socketPath = process.env.FORGE_SOCKET || `${process.env.HOME}/.forge/state/forge.sock`;
          const session = process.env.FORGE_SESSION;

          if (!process.env.FORGE_SOCKET && !process.env.FORGE_SESSION) return;

          function send(event: string, data: Record<string, any> = {}) {
            // New connection per message — ForgeSocketServer closes after each read
            try {
              const sock = net.createConnection(socketPath, () => {
                sock.end(JSON.stringify({
                  command: "agent_event", session, agent: "pi", event, data
                }) + "\\n");
              });
              sock.on("error", () => {});
            } catch {}
          }

          // Set terminal title so Forge's TerminalObserver can detect the agent
          function setTitle(t: string) { process.stdout.write(`\\x1b]0;${t}\\x07`); }

          pi.on("session_start", () => setTitle("pi"));
          pi.on("session_shutdown", () => setTitle(""));
          pi.on("agent_start", () => send("agent_start"));
          pi.on("agent_end", (e: any) => send("stop", { messages: e.messages?.length }));
          pi.on("turn_start", (e: any) => send("turn_start", { turnIndex: e.turnIndex }));
          pi.on("turn_end", (e: any) => send("turn_end", {
            toolResults: e.toolResults?.length
          }));
          pi.on("tool_execution_start", (e: any) => send("tool_start", {
            tool_name: e.toolName, tool_input: e.args, tool_use_id: e.toolCallId
          }));
          pi.on("tool_execution_end", (e: any) => send("tool_end", {
            tool_name: e.toolName, tool_use_id: e.toolCallId, isError: e.isError,
            result: typeof e.result === "string" ? e.result.slice(0, 2000) : undefined
          }));
          pi.on("message_start", () => send("message_start"));
          pi.on("message_end", () => send("message_end"));
          pi.on("compaction_start", () => send("compaction_start"));
          pi.on("compaction_end", () => send("compaction_end"));
          pi.on("auto_retry_start", (e: any) => send("retry_start", {
            attempt: e.attempt, maxRetries: e.maxRetries
          }));
        }
        """

        // Write or update if marker present
        if let existing = try? String(contentsOfFile: extensionPath, encoding: .utf8),
           existing.contains("FORGE_SOCKET")
        {
            // Already installed — update in place
            try? extensionCode.write(toFile: extensionPath, atomically: true, encoding: .utf8)
        } else if !fm.fileExists(atPath: extensionPath) {
            try? extensionCode.write(toFile: extensionPath, atomically: true, encoding: .utf8)
        }
        // If file exists but doesn't contain FORGE_SOCKET, don't overwrite user's file
    }

    // MARK: - OpenCode

    /// Drops forge-bridge.ts plugin into ~/.config/opencode/plugin/
    private func installOpenCodePlugin() {
        let configDir = NSHomeDirectory() + "/.config/opencode"
        let pluginDir = configDir + "/plugin"
        let pluginPath = pluginDir + "/forge-bridge.ts"
        let fm = FileManager.default

        // Only install if OpenCode config dir exists (or create plugin dir inside it)
        // OpenCode uses ~/.config/opencode/ as its global config dir
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: pluginDir) {
            try? fm.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
        }

        let pluginCode = """
        import * as net from "node:net";

        export const server = async (ctx) => {
          const socketPath = process.env.FORGE_SOCKET || `${process.env.HOME}/.forge/state/forge.sock`;
          const session = process.env.FORGE_SESSION;

          if (!process.env.FORGE_SOCKET && !process.env.FORGE_SESSION) return {};

          function send(event, data = {}) {
            try {
              const sock = net.createConnection(socketPath, () => {
                sock.end(JSON.stringify({
                  command: "agent_event", session, agent: "opencode", event, data
                }) + "\\n");
              });
              sock.on("error", () => {});
            } catch {}
          }

          return {
            event: async ({ event }) => {
              const type = event?.type || "";
              const props = event?.properties || event;

              switch (type) {
                case "session.status":
                  const status = props?.status?.type || props?.status;
                  if (status) send("status", { status });
                  break;
                case "permission.asked":
                  send("permission", props);
                  break;
                case "permission.replied":
                  send("permission_replied", props);
                  break;
                case "session.created":
                case "session.updated":
                  send("session_update", props);
                  break;
              }
            }
          };
        };
        """

        // Write or update if Forge marker present
        if let existing = try? String(contentsOfFile: pluginPath, encoding: .utf8),
           existing.contains("FORGE_SOCKET")
        {
            try? pluginCode.write(toFile: pluginPath, atomically: true, encoding: .utf8)
        } else if !fm.fileExists(atPath: pluginPath) {
            try? pluginCode.write(toFile: pluginPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Workspace Trust

    /// Trusts the Forge clones directory in Claude Code's config so new workspaces
    /// skip the interactive trust dialog. Claude Code walks up parent directories
    /// when checking trust, so a single entry for the clones dir covers all children.
    private func trustClaudeCodeClonesDir() {
        let configPath = NSHomeDirectory() + "/.claude.json"
        let fm = FileManager.default

        var config: [String: Any] = [:]
        if let data = fm.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            config = json
        }

        let clonesPath = ForgeStore.shared.clonesDir.path
        var projects = config["projects"] as? [String: Any] ?? [:]
        var projectEntry = projects[clonesPath] as? [String: Any] ?? [:]

        guard projectEntry["hasTrustDialogAccepted"] as? Bool != true else { return }

        projectEntry["hasTrustDialogAccepted"] = true
        projects[clonesPath] = projectEntry
        config["projects"] = projects

        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// Trusts a specific project path in Codex's config. Codex does not walk parent
    /// directories, so each workspace must be trusted individually at clone time.
    func trustCodexProject(path: String) {
        let configPath = NSHomeDirectory() + "/.codex/config.toml"
        let fm = FileManager.default
        guard fm.fileExists(atPath: (configPath as NSString).deletingLastPathComponent) else { return }

        var content = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""

        let tomlKey = "[projects.\"\(path)\"]"
        guard !content.contains(tomlKey) else { return }

        content += "\n\(tomlKey)\ntrust_level = \"trusted\"\n"
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    /// Removes trust for a workspace path from Codex's config when the workspace is deleted.
    func untrustCodexProject(path: String) {
        let configPath = NSHomeDirectory() + "/.codex/config.toml"
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }

        let tomlKey = "[projects.\"\(path)\"]"
        guard content.contains(tomlKey) else { return }

        // Remove the section header and its trust_level line
        var lines = content.components(separatedBy: "\n")
        if let idx = lines.firstIndex(where: { $0 == tomlKey }) {
            lines.remove(at: idx)
            // Remove the trust_level line immediately following
            if idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("trust_level") {
                lines.remove(at: idx)
            }
            // Remove any leftover blank line
            if idx < lines.count, lines[idx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               idx > 0, lines[idx - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                lines.remove(at: idx)
            }
        }

        try? lines.joined(separator: "\n").write(toFile: configPath, atomically: true, encoding: .utf8)
    }
}
