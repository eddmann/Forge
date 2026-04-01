import Foundation

/// Installs per-agent hooks, config files, and extensions on app startup.
/// Each agent gets its native integration mechanism — no uniform approach.
class AgentSetup {
    static let shared = AgentSetup()

    /// Marker comment used to identify Forge-managed hook entries.
    private static let forgeMarker = "forge event"

    private init() {}

    /// Install hooks/config/extensions for all known agents.
    func installAll() {
        installClaudeCodeHooks()
        installCodexHooks()
        installPiExtension()
        installOpenCodePlugin()
    }

    // MARK: - Claude Code

    /// Writes hooks to ~/.claude/settings.json (only if ~/.claude/ exists)
    private func installClaudeCodeHooks() {
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        let dir = (settingsPath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        // Only install if Claude Code is already set up
        guard fm.fileExists(atPath: dir) else { return }

        // Read existing settings
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Build hook entries — guarded by FORGE_SESSION so hooks only fire inside Forge
        // Uses if/then/fi (not &&) so exit code is always 0 when outside Forge
        func claudeHook(_ event: String) -> String {
            "if [ -n \"$FORGE_SESSION\" ]; then forge event claude \(event); fi"
        }
        let hooks: [String: Any] = [
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

        // Merge — replace existing Forge hooks, preserve user hooks
        var existingHooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, newEntries) in hooks {
            var eventEntries = existingHooks[event] as? [[String: Any]] ?? []
            // Remove old Forge entries (identified by "forge event" in command)
            eventEntries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    (hook["command"] as? String)?.contains(Self.forgeMarker) == true
                }
            }
            // Add new entries
            if let newArray = newEntries as? [[String: Any]] {
                eventEntries.append(contentsOf: newArray)
            }
            existingHooks[event] = eventEntries
        }
        settings["hooks"] = existingHooks

        // Write back
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
    }

    // MARK: - Codex

    /// Writes hooks to ~/.codex/hooks.json and TUI config to ~/.codex/config.toml (only if ~/.codex/ exists)
    private func installCodexHooks() {
        let codexDir = NSHomeDirectory() + "/.codex"
        let fm = FileManager.default

        // Only install if Codex is already set up
        guard fm.fileExists(atPath: codexDir) else { return }

        // hooks.json — guarded by FORGE_SESSION, if/then/fi for clean exit code
        let hooksPath = codexDir + "/hooks.json"
        func codexHook(_ event: String) -> String {
            "if [ -n \"$FORGE_SESSION\" ]; then forge event codex \(event); fi"
        }
        let hooks: [String: Any] = [
            "hooks": [
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
        ]

        // Read existing, merge Forge hooks
        var existingRoot: [String: Any] = [:]
        if let data = fm.contents(atPath: hooksPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existingRoot = json
        }

        var existingHooks = existingRoot["hooks"] as? [String: Any] ?? [:]
        let newHooks = hooks["hooks"] as? [String: Any] ?? [:]

        for (event, newEntries) in newHooks {
            var eventEntries = existingHooks[event] as? [[String: Any]] ?? []
            eventEntries.removeAll { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { hook in
                    (hook["command"] as? String)?.contains(Self.forgeMarker) == true
                }
            }
            if let newArray = newEntries as? [[String: Any]] {
                eventEntries.append(contentsOf: newArray)
            }
            existingHooks[event] = eventEntries
        }
        existingRoot["hooks"] = existingHooks

        if let data = try? JSONSerialization.data(withJSONObject: existingRoot, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: hooksPath))
        }

        // config.toml — enrich terminal title with status word
        let configPath = codexDir + "/config.toml"
        var configLines: [String] = []
        if let existing = try? String(contentsOfFile: configPath, encoding: .utf8) {
            configLines = existing.components(separatedBy: "\n")
        }

        // Check if [tui] section with terminal_title already exists
        let hasTuiTitle = configLines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("terminal_title") }
        if !hasTuiTitle {
            // Find or create [tui] section
            let hasTuiSection = configLines.contains { $0.trimmingCharacters(in: .whitespaces) == "[tui]" }
            if !hasTuiSection {
                configLines.append("")
                configLines.append("[tui]")
            }
            // Add terminal_title after [tui]
            if let tuiIndex = configLines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[tui]" }) {
                configLines.insert("terminal_title = [\"spinner\", \"status\", \"project\"]", at: tuiIndex + 1)
            }
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
           existing.contains("FORGE_SOCKET") {
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
           existing.contains("FORGE_SOCKET") {
            try? pluginCode.write(toFile: pluginPath, atomically: true, encoding: .utf8)
        } else if !fm.fileExists(atPath: pluginPath) {
            try? pluginCode.write(toFile: pluginPath, atomically: true, encoding: .utf8)
        }
    }
}
