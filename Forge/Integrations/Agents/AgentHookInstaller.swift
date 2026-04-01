import AppKit

/// Installs Forge status hooks into agent config files so agents
/// can report their status (running/waiting/idle) via FORGE_STATUS_FILE.
enum AgentHookInstaller {
    /// Marker embedded in hook commands so we can detect our hooks
    private static let forgeMarker = "FORGE_NOTIFY"
    /// Legacy marker from old file-based hooks
    private static let legacyMarker = "FORGE_STATUS_FILE"

    /// Directory for Forge helper scripts
    private static var hooksDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".forge/state/hooks")
    }

    // MARK: - Public

    /// Check all known agents and offer to install hooks if missing.
    /// Call once at app startup.
    static func installIfNeeded() {
        if ForgeStore.shared.loadStateFields().hooksDeclined { return }

        let agents = AgentStore.shared.agents
        var missing: [String] = []

        // Only check agents that are actually installed
        if agents.first(where: { $0.command == "claude" })?.isInstalled == true,
           !claudeCodeHooksInstalled()
        {
            missing.append("Claude Code")
        }
        if agents.first(where: { $0.command == "codex" })?.isInstalled == true,
           !codexHooksInstalled()
        {
            missing.append("Codex")
        }
        if agents.first(where: { $0.command == "opencode" })?.isInstalled == true,
           !openCodeHooksInstalled()
        {
            missing.append("OpenCode")
        }
        if agents.first(where: { $0.command == "gemini" })?.isInstalled == true,
           !geminiHooksInstalled()
        {
            missing.append("Gemini CLI")
        }
        if agents.first(where: { $0.command == "amp" })?.isInstalled == true,
           !ampHooksInstalled()
        {
            missing.append("Amp")
        }
        if agents.first(where: { $0.command == "pi" })?.isInstalled == true,
           !piHooksInstalled()
        {
            missing.append("Pi")
        }

        guard !missing.isEmpty else { return }

        let names = missing.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Install Agent Status Hooks?"
        alert.informativeText = "Forge can install lightweight hooks for \(names) so the tab bar shows live status indicators (running, waiting for input, idle).\n\nThe hooks only activate inside Forge and update each agent's local config or plugin files as needed."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Hooks")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            ensureHooksDir()
            if missing.contains("Claude Code") { installClaudeCodeHooks() }
            if missing.contains("Codex") { installCodexHooks() }
            if missing.contains("OpenCode") { installOpenCodeHooks() }
            if missing.contains("Gemini CLI") { installGeminiHooks() }
            if missing.contains("Amp") { installAmpHooks() }
            if missing.contains("Pi") { installPiHooks() }
        case .alertThirdButtonReturn:
            ForgeStore.shared.updateStateFields { $0.hooksDeclined = true }
        default:
            break
        }
    }

    private static func ensureHooksDir() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: hooksDir) {
            try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Claude Code

    private static var claudeSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    private static func claudeCodeHooksInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: claudeSettingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else {
            return false
        }
        // Check for NEW hooks (FORGE_NOTIFY), not legacy (FORGE_STATUS_FILE)
        return jsonContains(hooks, substring: forgeMarker)
    }

    private static func installClaudeCodeHooks() {
        let settingsDir = (claudeSettingsPath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        if !fm.fileExists(atPath: settingsDir) {
            try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings = json
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let writeRunning = claudeHookEntry(status: "running")
        let writeIdle = claudeHookEntry(status: "idle")

        mergeClaudeHookEvent(&hooks, event: "UserPromptSubmit", entry: writeRunning)
        mergeClaudeHookEvent(&hooks, event: "PreToolUse", entry: writeRunning)
        mergeClaudeHookEvent(&hooks, event: "Notification", entry: claudeNotificationEntry())
        mergeClaudeHookEvent(&hooks, event: "Stop", entry: writeIdle)
        mergeClaudeHookEvent(&hooks, event: "SessionEnd", entry: writeIdle)

        settings["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: claudeSettingsPath))
        }
    }

    private static func claudeHookEntry(status: String) -> [String: Any] {
        let command = switch status {
        case "idle":
            "[ -x \"$FORGE_NOTIFY\" ] && \"$FORGE_NOTIFY\" notify 'Claude Code' 'Task complete'"
        case "running":
            "[ -x \"$FORGE_NOTIFY\" ] && \"$FORGE_NOTIFY\" notify 'Claude Code' 'status:running'"
        default:
            "[ -x \"$FORGE_NOTIFY\" ] && \"$FORGE_NOTIFY\" notify 'Claude Code' 'status:\(status)'"
        }
        return [
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                    "async": true
                ] as [String: Any]
            ]
        ]
    }

    private static func claudeNotificationEntry() -> [String: Any] {
        [
            "matcher": "permission_prompt|elicitation_dialog",
            "hooks": [
                [
                    "type": "command",
                    "command": "[ -x \"$FORGE_NOTIFY\" ] && \"$FORGE_NOTIFY\" notify 'Claude Code' 'status:waiting'",
                    "async": true
                ] as [String: Any]
            ]
        ]
    }

    private static func mergeClaudeHookEvent(_ hooks: inout [String: Any], event: String, entry: [String: Any]) {
        var entries = hooks[event] as? [[String: Any]] ?? []
        // Remove any old Forge hooks (file-based or current)
        entries.removeAll { jsonContains($0, substring: forgeMarker) || jsonContains($0, substring: legacyMarker) }
        entries.append(entry)
        hooks[event] = entries
    }

    // MARK: - Codex

    private static var codexConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")
    }

    private static var codexNotifyScript: String {
        (hooksDir as NSString).appendingPathComponent("codex.sh")
    }

    private static func codexHooksInstalled() -> Bool {
        // Check if config.toml references our notify script
        guard FileManager.default.fileExists(atPath: codexConfigPath),
              let content = try? String(contentsOfFile: codexConfigPath, encoding: .utf8)
        else {
            return false
        }
        return content.contains(forgeMarker) || content.contains("codex.sh") || content.contains("codex-notify.sh")
    }

    private static func installCodexHooks() {
        let fm = FileManager.default

        // Create the notify script
        let script = """
        #!/bin/bash
        # Forge notification hook for Codex
        # Called by Codex on agent-turn-complete (JSON on stdin)
        [ -x "$FORGE_NOTIFY" ] && "$FORGE_NOTIFY" notify "Codex" "Task complete"
        """
        try? script.write(toFile: codexNotifyScript, atomically: true, encoding: .utf8)
        // Make executable
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexNotifyScript)

        // Ensure ~/.codex/ exists
        let codexDir = (codexConfigPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: codexDir) {
            try? fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        }

        // Read existing config or create new
        var config = (try? String(contentsOfFile: codexConfigPath, encoding: .utf8)) ?? ""

        // Add notify line if not present
        if !config.contains("notify") {
            if !config.isEmpty, !config.hasSuffix("\n") {
                config += "\n"
            }
            config += "\n# Forge status hook\nnotify = \"\(codexNotifyScript)\"\n"
            try? config.write(toFile: codexConfigPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - OpenCode

    private static var openCodePluginDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/opencode/plugins")
    }

    private static var openCodePluginPath: String {
        (openCodePluginDir as NSString).appendingPathComponent("forge-status.ts")
    }

    private static func openCodeHooksInstalled() -> Bool {
        FileManager.default.fileExists(atPath: openCodePluginPath)
    }

    private static func installOpenCodeHooks() {
        let fm = FileManager.default

        if !fm.fileExists(atPath: openCodePluginDir) {
            try? fm.createDirectory(atPath: openCodePluginDir, withIntermediateDirectories: true)
        }

        let plugin = """
        import { execSync } from "child_process";

        // Forge notification plugin for OpenCode
        const forgeCLI = process.env.FORGE_NOTIFY;

        function notify(title: string, body: string) {
            if (!forgeCLI) return;
            try { execSync(`"${forgeCLI}" notify "${title}" "${body}"`); } catch {}
        }

        export default {
            name: "forge-status",
            subscribe(ctx: any) {
                ctx.on("tool.execute.before", () => notify("OpenCode", "status:running"));
                ctx.on("session.idle", () => notify("OpenCode", "Task complete"));
                ctx.on("permission.updated", () => notify("OpenCode", "status:waiting"));
            }
        };
        """
        try? plugin.write(toFile: openCodePluginPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Gemini CLI

    private static var geminiSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/settings.json")
    }

    private static func geminiHooksInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: geminiSettingsPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: geminiSettingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any]
        else {
            return false
        }
        return jsonContains(hooks, substring: forgeMarker)
    }

    private static func installGeminiHooks() {
        let settingsDir = (geminiSettingsPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: settingsDir) {
            try? fm.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: geminiSettingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings = json
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let runningHook = geminiHookEntry(command: "[ -x \"$FORGE_NOTIFY\" ] && \"$FORGE_NOTIFY\" notify 'Gemini CLI' 'status:running'")
        let idleHook = geminiHookEntry(command: "[ -x \"$FORGE_NOTIFY\" ] && \"$FORGE_NOTIFY\" notify 'Gemini CLI' 'Task complete'")
        let waitingHook: [String: Any] = [
            "matcher": "ToolPermission",
            "hooks": [["type": "command", "command": "[ -x \"$FORGE_NOTIFY\" ] && \"$FORGE_NOTIFY\" notify 'Gemini CLI' 'status:waiting'"] as [String: Any]]
        ]

        mergeGeminiHookEvent(&hooks, event: "BeforeTool", entry: runningHook)
        mergeGeminiHookEvent(&hooks, event: "AfterAgent", entry: idleHook)
        mergeGeminiHookEvent(&hooks, event: "Notification", entry: waitingHook)

        settings["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: geminiSettingsPath))
        }
    }

    private static func geminiHookEntry(command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command] as [String: Any]]]
    }

    private static func mergeGeminiHookEvent(_ hooks: inout [String: Any], event: String, entry: [String: Any]) {
        var entries = hooks[event] as? [[String: Any]] ?? []
        entries.removeAll { jsonContains($0, substring: forgeMarker) }
        entries.append(entry)
        hooks[event] = entries
    }

    // MARK: - Amp

    private static var ampPluginDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/amp/plugins")
    }

    private static var ampPluginPath: String {
        (ampPluginDir as NSString).appendingPathComponent("forge-status.ts")
    }

    private static func ampHooksInstalled() -> Bool {
        FileManager.default.fileExists(atPath: ampPluginPath)
    }

    private static func installAmpHooks() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: ampPluginDir) {
            try? fm.createDirectory(atPath: ampPluginDir, withIntermediateDirectories: true)
        }

        let plugin = """
        // @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
        import { execSync } from "child_process";
        import type { PluginAPI } from "@ampcode/plugin";

        // Forge status plugin for Amp
        const forgeCLI = process.env.FORGE_NOTIFY;

        function notify(title: string, body: string) {
            if (!forgeCLI) return;
            try { execSync(`"${forgeCLI}" notify "${title}" "${body}"`); } catch {}
        }

        export default function(amp: PluginAPI) {
            amp.on("agent.start", async () => { notify("Amp", "status:running"); return {}; });
            amp.on("agent.end", async () => { notify("Amp", "Task complete"); return {}; });
            amp.on("tool.call", async (event: any, ctx: any) => {
                notify("Amp", "status:running");
                return { action: "allow" };
            });
        }
        """
        try? plugin.write(toFile: ampPluginPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Pi

    private static var piExtensionDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".pi/agent/extensions")
    }

    private static var piExtensionPath: String {
        (piExtensionDir as NSString).appendingPathComponent("forge-status.ts")
    }

    private static func piHooksInstalled() -> Bool {
        FileManager.default.fileExists(atPath: piExtensionPath)
    }

    private static func installPiHooks() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: piExtensionDir) {
            try? fm.createDirectory(atPath: piExtensionDir, withIntermediateDirectories: true)
        }

        let extension_ = """
        import { execSync } from "child_process";

        // Forge status extension for Pi
        const forgeCLI = process.env.FORGE_NOTIFY;

        function notify(title: string, body: string) {
            if (!forgeCLI) return;
            try { execSync(`"${forgeCLI}" notify "${title}" "${body}"`); } catch {};
        }

        export default function(pi: any) {
            pi.on("tool_call", async () => { notify("Pi", "status:running"); });
            pi.on("agent_end", async () => { notify("Pi", "Task complete"); });
        }
        """
        try? extension_.write(toFile: piExtensionPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    /// Recursively check if a JSON structure contains a string
    private static func jsonContains(_ obj: Any, substring: String) -> Bool {
        if let dict = obj as? [String: Any] {
            return dict.values.contains { jsonContains($0, substring: substring) }
        } else if let array = obj as? [Any] {
            return array.contains { jsonContains($0, substring: substring) }
        } else if let str = obj as? String {
            return str.contains(substring)
        }
        return false
    }
}
