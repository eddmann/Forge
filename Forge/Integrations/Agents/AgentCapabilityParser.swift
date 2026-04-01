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
        case "pi":
            parsePi(projectPath: projectPath, agent: agent)
        default:
            AgentCapabilities(
                agentName: agent.name,
                icon: agent.icon,
                isInstalled: agent.isInstalled,
                mcpServers: [],
                skills: [],
                plugins: [],
                instructions: []
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
            case "pi":
                parsePi(projectPath: projectPath, agent: agent)
            default:
                AgentCapabilities(
                    agentName: agent.name,
                    icon: agent.icon,
                    isInstalled: agent.isInstalled,
                    mcpServers: [],
                    skills: [],
                    plugins: [],
                    instructions: []
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

        // Project skills from <project>/.claude/skills/ (SKILL.md in subdirs + flat .md files)
        let projectSkillsDir = (projectPath as NSString).appendingPathComponent(".claude/skills")
        skills += parseSkillsDirectory(projectSkillsDir, scope: .project)
        skills += parseCommandsDirectory(projectSkillsDir, scope: .project)

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

        // Instructions — collect ALL sources (user-level, project, rules, local)
        // User-level CLAUDE.md
        let userClaudeMd = (home as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fm.fileExists(atPath: userClaudeMd) {
            instructions.append(AgentInstructions(fileName: "~/.claude/CLAUDE.md", filePath: userClaudeMd, exists: true))
        }

        // Project CLAUDE.md and .claude/CLAUDE.md (both can exist)
        let claudeMdRoot = (projectPath as NSString).appendingPathComponent("CLAUDE.md")
        let claudeMdNested = (projectPath as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fm.fileExists(atPath: claudeMdRoot) {
            instructions.append(AgentInstructions(fileName: "CLAUDE.md", filePath: claudeMdRoot, exists: true))
        }
        if fm.fileExists(atPath: claudeMdNested) {
            instructions.append(AgentInstructions(fileName: ".claude/CLAUDE.md", filePath: claudeMdNested, exists: true))
        }

        // .claude/rules/*.md (recursive)
        let rulesDir = (projectPath as NSString).appendingPathComponent(".claude/rules")
        if fm.fileExists(atPath: rulesDir) {
            let ruleFiles = scanRecursiveForMdFiles(rulesDir, scope: .project)
            for rule in ruleFiles {
                let displayName = ".claude/rules/" + ((rule.filePath as NSString).lastPathComponent)
                instructions.append(AgentInstructions(fileName: displayName, filePath: rule.filePath, exists: true))
            }
        }

        // CLAUDE.local.md (private, gitignored)
        let claudeLocalMd = (projectPath as NSString).appendingPathComponent("CLAUDE.local.md")
        if fm.fileExists(atPath: claudeLocalMd) {
            instructions.append(AgentInstructions(fileName: "CLAUDE.local.md", filePath: claudeLocalMd, exists: true))
        }

        return AgentCapabilities(
            agentName: agent.name,
            icon: agent.icon,
            isInstalled: agent.isInstalled,
            mcpServers: mcpServers,
            skills: skills,
            plugins: plugins,
            instructions: instructions
        )
    }

    // MARK: - Codex

    static func parseCodex(projectPath: String, agent: AgentConfig) -> AgentCapabilities {
        var mcpServers: [MCPServerInfo] = []
        var skills: [AgentSkillInfo] = []
        var instructions: [AgentInstructions] = []
        let codexHome = (home as NSString).appendingPathComponent(".codex")
        let gitRoot = findGitRoot(from: projectPath)

        // MCP servers from ~/.codex/config.toml (global)
        let globalConfigPath = (codexHome as NSString).appendingPathComponent("config.toml")
        if let content = try? String(contentsOfFile: globalConfigPath, encoding: .utf8) {
            mcpServers += parseMCPFromTOML(content, scope: .user)
        }

        // MCP servers from .codex/config.toml — walk from project to git root
        if let root = gitRoot {
            var current = projectPath
            while true {
                let configPath = (current as NSString).appendingPathComponent(".codex/config.toml")
                if let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
                    let projectServers = parseMCPFromTOML(content, scope: .project)
                    for server in projectServers where !mcpServers.contains(where: { $0.name == server.name }) {
                        mcpServers.append(server)
                    }
                }
                if current == root { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }

        // Skills from ~/.codex/skills/ (legacy user skills)
        skills += parseSkillsDirectory((codexHome as NSString).appendingPathComponent("skills"), scope: .user)

        // Skills from ~/.agents/skills/ (shared)
        skills += parseSkillsDirectory((home as NSString).appendingPathComponent(".agents/skills"), scope: .user)

        // Skills from .agents/skills/ — walk from git root to project path
        if let root = gitRoot {
            var dirs: [String] = []
            var current = projectPath
            while true {
                dirs.append(current)
                if current == root { break }
                current = (current as NSString).deletingLastPathComponent
            }
            for dir in dirs.reversed() {
                let skillsDir = (dir as NSString).appendingPathComponent(".agents/skills")
                skills += parseSkillsDirectory(skillsDir, scope: .project)
            }
        }

        // Instructions — user-level
        let overrideMd = (codexHome as NSString).appendingPathComponent("AGENTS.override.md")
        if fm.fileExists(atPath: overrideMd) {
            instructions.append(AgentInstructions(fileName: "~/.codex/AGENTS.override.md", filePath: overrideMd, exists: true))
        }
        let userAgentsMd = (codexHome as NSString).appendingPathComponent("AGENTS.md")
        if fm.fileExists(atPath: userAgentsMd) {
            instructions.append(AgentInstructions(fileName: "~/.codex/AGENTS.md", filePath: userAgentsMd, exists: true))
        }

        // Instructions — walk from git root to project path collecting all AGENTS.md
        if let root = gitRoot {
            var dirs: [String] = []
            var current = projectPath
            while true {
                dirs.append(current)
                if current == root { break }
                current = (current as NSString).deletingLastPathComponent
            }
            for dir in dirs.reversed() {
                let agentsMd = (dir as NSString).appendingPathComponent("AGENTS.md")
                if fm.fileExists(atPath: agentsMd), agentsMd != userAgentsMd {
                    let displayName: String
                    if dir == projectPath {
                        displayName = "AGENTS.md"
                    } else if agentsMd.hasPrefix(projectPath + "/") {
                        displayName = String(agentsMd.dropFirst(projectPath.count + 1))
                    } else {
                        // Ancestor directory above project — show relative to git root
                        let dirName = (dir as NSString).lastPathComponent
                        displayName = "../\(dirName)/AGENTS.md"
                    }
                    instructions.append(AgentInstructions(fileName: displayName, filePath: agentsMd, exists: true))
                }
            }
        }

        return AgentCapabilities(
            agentName: agent.name,
            icon: agent.icon,
            isInstalled: agent.isInstalled,
            mcpServers: mcpServers,
            skills: skills,
            plugins: [],
            instructions: instructions
        )
    }

    // MARK: - OpenCode

    static func parseOpenCode(projectPath: String, agent: AgentConfig) -> AgentCapabilities {
        var mcpServers: [MCPServerInfo] = []
        var skills: [AgentSkillInfo] = []
        var plugins: [AgentPluginInfo] = []
        var instructions: [AgentInstructions] = []
        let globalConfigDir = (home as NSString).appendingPathComponent(".config/opencode")
        let gitRoot = findGitRoot(from: projectPath)

        // MCP servers from global config (first found wins)
        for name in ["opencode.jsonc", "opencode.json", ".opencode.json", "config.json"] {
            let path = (globalConfigDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) {
                parseMCPFromOpenCodeJSON(path, scope: .user, into: &mcpServers)
                break
            }
        }

        // MCP servers from project config (first found wins)
        for name in ["opencode.jsonc", "opencode.json", ".opencode.json"] {
            let path = (projectPath as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) {
                parseMCPFromOpenCodeJSON(path, scope: .project, into: &mcpServers)
                break
            }
        }

        // Skills — external directories (shared with Claude/Codex ecosystem)
        skills += parseSkillsDirectory((home as NSString).appendingPathComponent(".claude/skills"), scope: .user)
        skills += parseSkillsDirectory((home as NSString).appendingPathComponent(".agents/skills"), scope: .user)

        // Skills — project-level external directories
        skills += parseSkillsDirectory((projectPath as NSString).appendingPathComponent(".claude/skills"), scope: .project)
        skills += parseSkillsDirectory((projectPath as NSString).appendingPathComponent(".agents/skills"), scope: .project)

        // Skills — OpenCode native directories
        skills += parseSkillsDirectory((projectPath as NSString).appendingPathComponent(".opencode/skill"), scope: .project)
        skills += parseSkillsDirectory((projectPath as NSString).appendingPathComponent(".opencode/skills"), scope: .project)

        // Commands from ~/.opencode/commands/*.md and ~/.opencode/command/*.md
        skills += parseCommandsDirectory((home as NSString).appendingPathComponent(".opencode/commands"), scope: .user)
        skills += parseCommandsDirectory((home as NSString).appendingPathComponent(".opencode/command"), scope: .user)

        // Commands from <project>/.opencode/commands/*.md and .opencode/command/*.md
        skills += parseCommandsDirectory((projectPath as NSString).appendingPathComponent(".opencode/commands"), scope: .project)
        skills += parseCommandsDirectory((projectPath as NSString).appendingPathComponent(".opencode/command"), scope: .project)

        // Plugins from .opencode/plugin[s]/ directories
        plugins += scanExtensionDirectory((projectPath as NSString).appendingPathComponent(".opencode/plugin"))
        plugins += scanExtensionDirectory((projectPath as NSString).appendingPathComponent(".opencode/plugins"))
        plugins += scanExtensionDirectory((globalConfigDir as NSString).appendingPathComponent("plugin"))

        // Instructions — findUp from project to git root for AGENTS.md, CLAUDE.md, CONTEXT.md
        let stopPath = gitRoot ?? projectPath
        instructions += findInstructionFiles(names: ["AGENTS.md", "CLAUDE.md", "CONTEXT.md"], startPath: projectPath, stopPath: stopPath)

        // Instructions — global
        let globalAgentsMd = (globalConfigDir as NSString).appendingPathComponent("AGENTS.md")
        if fm.fileExists(atPath: globalAgentsMd) {
            instructions.append(AgentInstructions(fileName: "~/.config/opencode/AGENTS.md", filePath: globalAgentsMd, exists: true))
        }
        let claudeGlobalMd = (home as NSString).appendingPathComponent(".claude/CLAUDE.md")
        if fm.fileExists(atPath: claudeGlobalMd) {
            instructions.append(AgentInstructions(fileName: "~/.claude/CLAUDE.md", filePath: claudeGlobalMd, exists: true))
        }

        return AgentCapabilities(
            agentName: agent.name,
            icon: agent.icon,
            isInstalled: agent.isInstalled,
            mcpServers: mcpServers,
            skills: skills,
            plugins: plugins,
            instructions: instructions
        )
    }

    // MARK: - Pi

    static func parsePi(projectPath: String, agent: AgentConfig) -> AgentCapabilities {
        var skills: [AgentSkillInfo] = []
        var plugins: [AgentPluginInfo] = []
        var instructions: [AgentInstructions] = []
        let piAgentDir = (home as NSString).appendingPathComponent(".pi/agent")
        let gitRoot = findGitRoot(from: projectPath)

        // Skills from ~/.pi/agent/skills/ and .pi/skills/
        skills += parseSkillsDirectory((piAgentDir as NSString).appendingPathComponent("skills"), scope: .user)
        skills += parseSkillsDirectory((projectPath as NSString).appendingPathComponent(".pi/skills"), scope: .project)

        // Prompts (displayed as skills) from ~/.pi/agent/prompts/ and .pi/prompts/
        skills += parseCommandsDirectory((piAgentDir as NSString).appendingPathComponent("prompts"), scope: .user)
        skills += parseCommandsDirectory((projectPath as NSString).appendingPathComponent(".pi/prompts"), scope: .project)

        // Extensions (displayed as plugins) from ~/.pi/agent/extensions/ and .pi/extensions/
        plugins += scanExtensionDirectory((piAgentDir as NSString).appendingPathComponent("extensions"))
        plugins += scanExtensionDirectory((projectPath as NSString).appendingPathComponent(".pi/extensions"))

        // Instructions — project-level .pi/ directory
        let piProjectAgentsMd = (projectPath as NSString).appendingPathComponent(".pi/AGENTS.md")
        if fm.fileExists(atPath: piProjectAgentsMd) {
            instructions.append(AgentInstructions(fileName: ".pi/AGENTS.md", filePath: piProjectAgentsMd, exists: true))
        }
        let piProjectClaudeMd = (projectPath as NSString).appendingPathComponent(".pi/CLAUDE.md")
        if fm.fileExists(atPath: piProjectClaudeMd) {
            instructions.append(AgentInstructions(fileName: ".pi/CLAUDE.md", filePath: piProjectClaudeMd, exists: true))
        }

        // Instructions — ancestor walk for AGENTS.md and CLAUDE.md
        let stopPath = gitRoot ?? projectPath
        instructions += findInstructionFiles(names: ["AGENTS.md", "CLAUDE.md"], startPath: projectPath, stopPath: stopPath)

        // Instructions — global
        let globalAgentsMd = (piAgentDir as NSString).appendingPathComponent("AGENTS.md")
        if fm.fileExists(atPath: globalAgentsMd) {
            instructions.append(AgentInstructions(fileName: "~/.pi/agent/AGENTS.md", filePath: globalAgentsMd, exists: true))
        }
        let globalClaudeMd = (piAgentDir as NSString).appendingPathComponent("CLAUDE.md")
        if fm.fileExists(atPath: globalClaudeMd) {
            instructions.append(AgentInstructions(fileName: "~/.pi/agent/CLAUDE.md", filePath: globalClaudeMd, exists: true))
        }

        // Instructions — SYSTEM.md and APPEND_SYSTEM.md
        for name in ["SYSTEM.md", "APPEND_SYSTEM.md"] {
            let projectPath_ = (projectPath as NSString).appendingPathComponent(".pi/\(name)")
            if fm.fileExists(atPath: projectPath_) {
                instructions.append(AgentInstructions(fileName: ".pi/\(name)", filePath: projectPath_, exists: true))
            }
            let globalPath = (piAgentDir as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: globalPath) {
                instructions.append(AgentInstructions(fileName: "~/.pi/agent/\(name)", filePath: globalPath, exists: true))
            }
        }

        return AgentCapabilities(
            agentName: agent.name,
            icon: agent.icon,
            isInstalled: agent.isInstalled,
            mcpServers: [],
            skills: skills,
            plugins: plugins,
            instructions: instructions
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

    /// Walk upward from `path` to find the nearest `.git` directory, returning the containing directory.
    private static func findGitRoot(from path: String) -> String? {
        var current = path
        while current != "/" {
            let gitPath = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                return current
            }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Walk from `startPath` up to `stopPath`, checking each directory for files matching `names`.
    /// Returns all found files as AgentInstructions (deduped by filePath).
    private static func findInstructionFiles(names: [String], startPath: String, stopPath: String? = nil) -> [AgentInstructions] {
        var results: [AgentInstructions] = []
        var seen = Set<String>()
        var current = startPath
        let stop = stopPath ?? "/"

        while true {
            for name in names {
                let filePath = (current as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: filePath), !seen.contains(filePath) {
                    seen.insert(filePath)
                    // Show path relative to startPath for nested files
                    let displayName: String
                    if current == startPath {
                        displayName = name
                    } else {
                        let relative = String(current.dropFirst(startPath.count + 1))
                        displayName = (relative as NSString).appendingPathComponent(name)
                    }
                    results.append(AgentInstructions(fileName: displayName, filePath: filePath, exists: true))
                }
            }
            if current == stop || current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return results
    }

    /// Recursively scan a directory for .md files. Used for .claude/rules/ etc.
    private static func scanRecursiveForMdFiles(_ dirPath: String, scope: CapabilityScope) -> [AgentSkillInfo] {
        var results: [AgentSkillInfo] = []
        guard let enumerator = fm.enumerator(atPath: dirPath) else { return results }
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".md") else { continue }
            let filePath = (dirPath as NSString).appendingPathComponent(relativePath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else { continue }
            if let content = try? String(contentsOfFile: filePath, encoding: .utf8) {
                let frontmatter = parseFrontmatter(content)
                let name = frontmatter["name"] ?? String(relativePath.dropLast(3))
                results.append(AgentSkillInfo(
                    name: name,
                    description: frontmatter["description"],
                    filePath: filePath,
                    scope: scope
                ))
            }
        }
        return results
    }

    /// Scan a directory for .ts/.js extension files and subdirectories with index.ts/index.js.
    /// Returns them as AgentPluginInfo entries.
    private static func scanExtensionDirectory(_ dirPath: String) -> [AgentPluginInfo] {
        var results: [AgentPluginInfo] = []
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else { return results }
        for entry in entries.sorted() {
            let entryPath = (dirPath as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entryPath, isDirectory: &isDir)
            if isDir.boolValue {
                // Check for index.ts or index.js inside subdirectory
                let indexTs = (entryPath as NSString).appendingPathComponent("index.ts")
                let indexJs = (entryPath as NSString).appendingPathComponent("index.js")
                if fm.fileExists(atPath: indexTs) || fm.fileExists(atPath: indexJs) {
                    results.append(AgentPluginInfo(name: entry, version: nil, enabled: true))
                }
            } else if entry.hasSuffix(".ts") || entry.hasSuffix(".js") {
                let name = String((entry as NSString).deletingPathExtension)
                results.append(AgentPluginInfo(name: name, version: nil, enabled: true))
            }
        }
        return results
    }
}
