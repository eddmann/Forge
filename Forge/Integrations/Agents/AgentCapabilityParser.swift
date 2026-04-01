import Foundation

enum AgentCapabilityParser {
    private static let fm = FileManager.default
    private static let home = fm.homeDirectoryForCurrentUser.path

    // MARK: - Public API

    static func parse(agent: AgentConfig, projectPath: String) -> AgentCapabilities {
        switch agent.command {
        case "claude":
            parseClaudeCode(projectPath: projectPath, agent: agent)
        case "codex":
            parseCodex(projectPath: projectPath, agent: agent)
        case "opencode":
            parseOpenCode(projectPath: projectPath, agent: agent)
        default:
            AgentCapabilities(
                agentName: agent.name,
                icon: agent.icon,
                isInstalled: agent.isInstalled,
                mcpServers: [],
                skills: [],
                plugins: [],
                instructions: [],
                model: nil
            )
        }
    }

    static func parseAll(projectPath: String) -> [AgentCapabilities] {
        let agents = AgentStore.shared.agents
        return agents.compactMap { agent in
            switch agent.command {
            case "claude":
                parseClaudeCode(projectPath: projectPath, agent: agent)
            case "codex":
                parseCodex(projectPath: projectPath, agent: agent)
            case "opencode":
                parseOpenCode(projectPath: projectPath, agent: agent)
            default:
                AgentCapabilities(
                    agentName: agent.name,
                    icon: agent.icon,
                    isInstalled: agent.isInstalled,
                    mcpServers: [],
                    skills: [],
                    plugins: [],
                    instructions: [],
                    model: nil
                )
            }
        }
    }

    // MARK: - Claude Code

    static func parseClaudeCode(projectPath: String, agent: AgentConfig) -> AgentCapabilities {
        var mcpServers: [MCPServerInfo] = []
        var skills: [AgentSkillInfo] = []
        var plugins: [AgentPluginInfo] = []
        var instructions: [AgentInstructions] = []

        // MCP servers from ~/.claude.json
        let claudeJsonPath = (home as NSString).appendingPathComponent(".claude.json")
        if let data = fm.contents(atPath: claudeJsonPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            // Global MCP servers (top-level mcpServers key)
            if let globalServers = json["mcpServers"] as? [String: Any] {
                for (name, value) in globalServers.sorted(by: { $0.key < $1.key }) {
                    if let serverDict = value as? [String: Any] {
                        let info = parseMCPServerDict(name: name, dict: serverDict, scope: .user)
                        mcpServers.append(info)
                    }
                }
            }
            // Per-project MCP servers
            if let projects = json["projects"] as? [String: Any],
               let projectConfig = projects[projectPath] as? [String: Any],
               let servers = projectConfig["mcpServers"] as? [String: Any]
            {
                for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                    if let serverDict = value as? [String: Any] {
                        // Skip if already added from global
                        if !mcpServers.contains(where: { $0.name == name }) {
                            let info = parseMCPServerDict(name: name, dict: serverDict, scope: .project)
                            mcpServers.append(info)
                        }
                    }
                }
            }
        }

        // MCP servers from <project>/.mcp.json
        let mcpJsonPath = (projectPath as NSString).appendingPathComponent(".mcp.json")
        if let data = fm.contents(atPath: mcpJsonPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any]
        {
            for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                if let serverDict = value as? [String: Any] {
                    let info = parseMCPServerDict(name: name, dict: serverDict, scope: .project)
                    mcpServers.append(info)
                }
            }
        }

        // Skills from ~/.claude/skills/*/SKILL.md
        let skillsDir = (home as NSString).appendingPathComponent(".claude/skills")
        if let entries = try? fm.contentsOfDirectory(atPath: skillsDir) {
            for entry in entries.sorted() {
                let entryPath = (skillsDir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entryPath, isDirectory: &isDir), isDir.boolValue {
                    let skillFile = (entryPath as NSString).appendingPathComponent("SKILL.md")
                    if let content = try? String(contentsOfFile: skillFile, encoding: .utf8) {
                        let frontmatter = parseFrontmatter(content)
                        skills.append(AgentSkillInfo(
                            name: frontmatter["name"] ?? entry,
                            description: frontmatter["description"],
                            filePath: skillFile,
                            scope: .user
                        ))
                    }
                } else if entry.hasSuffix(".md"), entry != "PLAN.md" {
                    let name = String(entry.dropLast(3))
                    if let content = try? String(contentsOfFile: entryPath, encoding: .utf8) {
                        let frontmatter = parseFrontmatter(content)
                        skills.append(AgentSkillInfo(
                            name: frontmatter["name"] ?? name,
                            description: frontmatter["description"],
                            filePath: entryPath,
                            scope: .user
                        ))
                    }
                }
            }
        }

        // Project commands from <project>/.claude/commands/*.md
        let projectCommandsDir = (projectPath as NSString).appendingPathComponent(".claude/commands")
        if let entries = try? fm.contentsOfDirectory(atPath: projectCommandsDir) {
            for entry in entries.sorted() where entry.hasSuffix(".md") {
                let name = String(entry.dropLast(3))
                let filePath = (projectCommandsDir as NSString).appendingPathComponent(entry)
                if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                    let frontmatter = parseFrontmatter(content)
                    skills.append(AgentSkillInfo(
                        name: frontmatter["name"] ?? name,
                        description: frontmatter["description"],
                        filePath: filePath,
                        scope: .project
                    ))
                }
            }
        }

        // Plugins from ~/.claude/plugins/installed_plugins.json
        let pluginsPath = (home as NSString).appendingPathComponent(".claude/plugins/installed_plugins.json")
        let settingsPath = (home as NSString).appendingPathComponent(".claude/settings.json")
        var enabledPlugins: [String: Bool] = [:]

        if let data = fm.contents(atPath: settingsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let enabled = json["enabledPlugins"] as? [String: Bool]
        {
            enabledPlugins = enabled
        }

        if let data = fm.contents(atPath: pluginsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pluginsDict = json["plugins"] as? [String: Any]
        {
            for (key, value) in pluginsDict.sorted(by: { $0.key < $1.key }) {
                if let entries = value as? [[String: Any]], let first = entries.first {
                    let version = first["version"] as? String
                    let enabled = enabledPlugins[key] ?? false
                    let displayName = key.components(separatedBy: "@").first ?? key
                    plugins.append(AgentPluginInfo(
                        name: displayName,
                        version: version,
                        enabled: enabled
                    ))
                }
            }
        }

        // Instructions
        let claudeMdRoot = (projectPath as NSString).appendingPathComponent("CLAUDE.md")
        let claudeMdNested = (projectPath as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fm.fileExists(atPath: claudeMdRoot) {
            instructions.append(AgentInstructions(fileName: "CLAUDE.md", filePath: claudeMdRoot, exists: true))
        } else if fm.fileExists(atPath: claudeMdNested) {
            instructions.append(AgentInstructions(fileName: ".claude/CLAUDE.md", filePath: claudeMdNested, exists: true))
        }

        return AgentCapabilities(
            agentName: agent.name,
            icon: agent.icon,
            isInstalled: agent.isInstalled,
            mcpServers: mcpServers,
            skills: skills,
            plugins: plugins,
            instructions: instructions,
            model: nil
        )
    }

    // MARK: - Codex

    static func parseCodex(projectPath: String, agent: AgentConfig) -> AgentCapabilities {
        var mcpServers: [MCPServerInfo] = []
        var skills: [AgentSkillInfo] = []
        var instructions: [AgentInstructions] = []
        var model: String?

        // Parse ~/.codex/config.toml (global)
        let globalConfigPath = (home as NSString).appendingPathComponent(".codex/config.toml")
        if let content = try? String(contentsOfFile: globalConfigPath, encoding: .utf8) {
            let lines = content.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("model"), trimmed.contains("=") {
                    model = extractTOMLStringValue(trimmed)
                    break
                }
            }
            mcpServers += parseMCPFromTOML(content, scope: .user)
        }

        // Parse <project>/.codex/config.toml (project-scoped)
        let projectConfigPath = (projectPath as NSString).appendingPathComponent(".codex/config.toml")
        if let content = try? String(contentsOfFile: projectConfigPath, encoding: .utf8) {
            let projectServers = parseMCPFromTOML(content, scope: .project)
            for server in projectServers where !mcpServers.contains(where: { $0.name == server.name }) {
                mcpServers.append(server)
            }
        }

        // Skills from ~/.codex/skills/*/SKILL.md
        let codexSkillsDir = (home as NSString).appendingPathComponent(".codex/skills")
        skills += parseSkillsDirectory(codexSkillsDir, scope: .user)

        // Skills from ~/.agents/skills/*/SKILL.md
        let agentsSkillsDir = (home as NSString).appendingPathComponent(".agents/skills")
        skills += parseSkillsDirectory(agentsSkillsDir, scope: .user)

        // Skills from <project>/.agents/skills/*/SKILL.md
        let projectAgentsSkillsDir = (projectPath as NSString).appendingPathComponent(".agents/skills")
        skills += parseSkillsDirectory(projectAgentsSkillsDir, scope: .project)

        // Instructions
        let agentsMd = (projectPath as NSString).appendingPathComponent("AGENTS.md")
        if fm.fileExists(atPath: agentsMd) {
            instructions.append(AgentInstructions(fileName: "AGENTS.md", filePath: agentsMd, exists: true))
        }

        return AgentCapabilities(
            agentName: agent.name,
            icon: agent.icon,
            isInstalled: agent.isInstalled,
            mcpServers: mcpServers,
            skills: skills,
            plugins: [],
            instructions: instructions,
            model: model
        )
    }

    // MARK: - OpenCode

    static func parseOpenCode(projectPath: String, agent: AgentConfig) -> AgentCapabilities {
        var mcpServers: [MCPServerInfo] = []
        var skills: [AgentSkillInfo] = []
        var instructions: [AgentInstructions] = []
        var model: String?

        // MCP servers from ~/.config/opencode/.opencode.json
        let globalConfigPath = (home as NSString).appendingPathComponent(".config/opencode/.opencode.json")
        parseMCPFromOpenCodeJSON(globalConfigPath, scope: .user, into: &mcpServers)

        // MCP servers from <project>/.opencode.json
        let projectConfigPath = (projectPath as NSString).appendingPathComponent(".opencode.json")
        parseMCPFromOpenCodeJSON(projectConfigPath, scope: .project, into: &mcpServers)

        // Model from .opencode.json
        for path in [projectConfigPath, globalConfigPath] {
            if model == nil,
               let data = fm.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let agents = json["agents"] as? [String: Any],
               let coder = agents["coder"] as? [String: Any],
               let m = coder["model"] as? String
            {
                model = m
            }
        }

        // Commands from ~/.opencode/commands/*.md
        let globalCommandsDir = (home as NSString).appendingPathComponent(".opencode/commands")
        skills += parseCommandsDirectory(globalCommandsDir, scope: .user)

        // Commands from <project>/.opencode/commands/*.md
        let projectCommandsDir = (projectPath as NSString).appendingPathComponent(".opencode/commands")
        skills += parseCommandsDirectory(projectCommandsDir, scope: .project)

        // Instructions
        let opencodeMd = (projectPath as NSString).appendingPathComponent("opencode.md")
        let cursorRules = (projectPath as NSString).appendingPathComponent(".cursorrules")
        if fm.fileExists(atPath: opencodeMd) {
            instructions.append(AgentInstructions(fileName: "opencode.md", filePath: opencodeMd, exists: true))
        } else if fm.fileExists(atPath: cursorRules) {
            instructions.append(AgentInstructions(fileName: ".cursorrules", filePath: cursorRules, exists: true))
        }

        return AgentCapabilities(
            agentName: agent.name,
            icon: agent.icon,
            isInstalled: agent.isInstalled,
            mcpServers: mcpServers,
            skills: skills,
            plugins: [],
            instructions: instructions,
            model: model
        )
    }

    // MARK: - Helpers

    private static func parseMCPFromTOML(_ content: String, scope: CapabilityScope) -> [MCPServerInfo] {
        var servers: [MCPServerInfo] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") {
                let serverName = String(trimmed.dropFirst("[mcp_servers.".count).dropLast())
                var command: String?
                var url: String?
                var enabled = true
                var j = i + 1

                while j < lines.count {
                    let sLine = lines[j].trimmingCharacters(in: .whitespaces)
                    if sLine.hasPrefix("[") { break }
                    if sLine.isEmpty || sLine.hasPrefix("#") { j += 1; continue }

                    if sLine.hasPrefix("command") {
                        command = extractTOMLStringValue(sLine)
                    } else if sLine.hasPrefix("url") {
                        url = extractTOMLStringValue(sLine)
                    } else if sLine.hasPrefix("enabled"), sLine.contains("false") {
                        enabled = false
                    }
                    j += 1
                }

                if enabled {
                    let serverType: MCPServerInfo.ServerType = url != nil ? .http : .stdio
                    servers.append(MCPServerInfo(
                        name: serverName,
                        commandOrURL: url ?? command ?? "",
                        type: serverType,
                        scope: scope
                    ))
                }
                i = j
                continue
            }
            i += 1
        }
        return servers
    }

    private static func parseMCPServerDict(name: String, dict: [String: Any], scope: CapabilityScope) -> MCPServerInfo {
        let typeStr = dict["type"] as? String ?? "stdio"
        let serverType: MCPServerInfo.ServerType = switch typeStr {
        case "sse": .sse
        case "http": .http
        default: .stdio
        }

        let commandOrURL: String
        if let url = dict["url"] as? String {
            commandOrURL = url
        } else if let command = dict["command"] as? String {
            let args = dict["args"] as? [String] ?? []
            commandOrURL = ([command] + args).joined(separator: " ")
        } else {
            commandOrURL = ""
        }

        return MCPServerInfo(name: name, commandOrURL: commandOrURL, type: serverType, scope: scope)
    }

    private static func parseFrontmatter(_ content: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }

        for i in 1 ..< lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line == "---" { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex ..< colonIndex]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                // Strip surrounding quotes
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                result[key] = value
            }
        }
        return result
    }

    private static func extractTOMLStringValue(_ line: String) -> String? {
        guard let eqIndex = line.firstIndex(of: "=") else { return nil }
        var value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func parseSkillsDirectory(_ dirPath: String, scope: CapabilityScope) -> [AgentSkillInfo] {
        var skills: [AgentSkillInfo] = []
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return skills }
        for entry in entries.sorted() {
            let entryPath = (dirPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entryPath, isDirectory: &isDir), isDir.boolValue {
                let skillFile = (entryPath as NSString).appendingPathComponent("SKILL.md")
                if let content = try? String(contentsOfFile: skillFile, encoding: .utf8) {
                    let frontmatter = parseFrontmatter(content)
                    skills.append(AgentSkillInfo(
                        name: frontmatter["name"] ?? entry,
                        description: frontmatter["description"],
                        filePath: skillFile,
                        scope: scope
                    ))
                }
            }
        }
        return skills
    }

    private static func parseCommandsDirectory(_ dirPath: String, scope: CapabilityScope) -> [AgentSkillInfo] {
        var commands: [AgentSkillInfo] = []
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return commands }
        for entry in entries.sorted() where entry.hasSuffix(".md") {
            let name = String(entry.dropLast(3))
            let filePath = (dirPath as NSString).appendingPathComponent(entry)
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                let frontmatter = parseFrontmatter(content)
                commands.append(AgentSkillInfo(
                    name: frontmatter["name"] ?? name,
                    description: frontmatter["description"],
                    filePath: filePath,
                    scope: scope
                ))
            }
        }
        return commands
    }

    private static func parseMCPFromOpenCodeJSON(_ path: String, scope: CapabilityScope, into servers: inout [MCPServerInfo]) {
        guard let data = fm.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any] else { return }
        for (name, value) in mcpServers.sorted(by: { $0.key < $1.key }) {
            if let serverDict = value as? [String: Any] {
                let info = parseMCPServerDict(name: name, dict: serverDict, scope: scope)
                servers.append(info)
            }
        }
    }
}
