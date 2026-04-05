import Foundation

// MARK: - Model

struct ProjectCommand: Identifiable {
    let id = UUID()
    let name: String
    let command: String
    let source: Source
    let workingDirectory: String?
    var detail: [DetailItem] = []

    init(
        name: String,
        command: String,
        source: Source,
        workingDirectory: String? = nil,
        detail: [DetailItem] = []
    ) {
        self.name = name
        self.command = command
        self.source = source
        self.workingDirectory = workingDirectory
        self.detail = detail
    }

    struct DetailItem {
        let label: String
        let value: String
    }

    enum Source: String {
        case forgeJson = "forge"
        case packageJson = "pkg"
        case makefile = "make"
        case dockerCompose = "docker"
        case justfile = "just"
        case pyprojectToml = "python"
        case cargoToml = "cargo"
        case denoJson = "deno"
        case composerJson = "composer"
        case rakefile = "rake"
        case procfile = "proc"
        case taskfileYml = "task"
        case goMod = "go"
        case swiftPackage = "swift"
        case xcodeproj = "xcode"

        var label: String {
            switch self {
            case .forgeJson: "Forge"
            case .packageJson: "package.json"
            case .makefile: "Makefile"
            case .dockerCompose: "docker-compose.yml"
            case .justfile: "justfile"
            case .pyprojectToml: "pyproject.toml"
            case .cargoToml: "Cargo.toml"
            case .denoJson: "deno.json"
            case .composerJson: "composer.json"
            case .rakefile: "Rakefile"
            case .procfile: "Procfile"
            case .taskfileYml: "Taskfile.yml"
            case .goMod: "go.mod"
            case .swiftPackage: "Package.swift"
            case .xcodeproj: "Xcode project"
            }
        }
    }
}

// MARK: - Discovery

func discoverProjectCommands(at path: String) -> [ProjectCommand] {
    var all: [ProjectCommand] = []

    // forge.json commands scanned first — they take precedence over auto-discovered ones
    all.append(contentsOf: scanForgeJson(at: path))
    all.append(contentsOf: scanPackageJson(at: path))
    all.append(contentsOf: scanMakefile(at: path))
    all.append(contentsOf: scanDockerCompose(at: path))
    all.append(contentsOf: scanJustfile(at: path))
    all.append(contentsOf: scanPyprojectToml(at: path))
    all.append(contentsOf: scanCargoToml(at: path))
    all.append(contentsOf: scanDenoJson(at: path))
    all.append(contentsOf: scanComposerJson(at: path))
    all.append(contentsOf: scanRakefile(at: path))
    all.append(contentsOf: scanProcfile(at: path))
    all.append(contentsOf: scanTaskfileYml(at: path))
    all.append(contentsOf: scanGoMod(at: path))
    all.append(contentsOf: scanSwiftPackage(at: path))
    all.append(contentsOf: scanXcodeproj(at: path))

    return dedupeCommands(all)
}

// MARK: - forge.json

private func scanForgeJson(at path: String) -> [ProjectCommand] {
    guard let config = ForgeConfig.load(from: path),
          let commands = config.commands else { return [] }

    return commands.map { name, commandConfig in
        var detail: [ProjectCommand.DetailItem] = []
        if let description = commandConfig.detail {
            detail.append(ProjectCommand.DetailItem(label: "Description", value: description))
        }
        return ProjectCommand(
            name: name,
            command: commandConfig.command,
            source: .forgeJson,
            workingDirectory: path,
            detail: detail
        )
    }.sorted { $0.name < $1.name }
}

// MARK: - package.json

private func scanPackageJson(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("package.json")
    guard let data = FileManager.default.contents(atPath: filePath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let scripts = json["scripts"] as? [String: String] else { return [] }

    let pkgName = json["name"] as? String
    // Detect if bun is the package manager (bun.lockb present)
    let useBun = FileManager.default.fileExists(
        atPath: (path as NSString).appendingPathComponent("bun.lockb")
    )
    let runner = useBun ? "bun run" : "npm run"

    return scripts.sorted(by: { $0.key < $1.key }).map { name, script in
        var detail: [ProjectCommand.DetailItem] = [
            .init(label: "Script", value: script)
        ]
        if let pkgName {
            detail.append(.init(label: "Package", value: pkgName))
        }
        if useBun {
            detail.append(.init(label: "Runner", value: "bun"))
        }
        return ProjectCommand(
            name: name,
            command: "\(runner) \(name)",
            source: .packageJson,
            detail: detail
        )
    }
}

// MARK: - Makefile

private func scanMakefile(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("Makefile")
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = []
    let lines = contents.components(separatedBy: "\n")
    var i = 0

    while i < lines.count {
        let line = lines[i]
        if let match = line.range(of: #"^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.*)"#, options: .regularExpression) {
            let matched = String(line[match])
            let colonIdx = matched.firstIndex(of: ":")!
            let target = String(matched[matched.startIndex ..< colonIdx])
            let deps = matched[matched.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)

            if !target.hasPrefix("."), !target.hasPrefix("_") {
                var detail: [ProjectCommand.DetailItem] = []
                if !deps.isEmpty {
                    detail.append(.init(label: "Depends on", value: deps))
                }
                var recipe: [String] = []
                var j = i + 1
                while j < lines.count, lines[j].hasPrefix("\t") || lines[j].hasPrefix("    ") {
                    recipe.append(lines[j].trimmingCharacters(in: .whitespaces))
                    j += 1
                }
                if !recipe.isEmpty {
                    detail.append(.init(label: "Recipe", value: recipe.joined(separator: "\n")))
                }
                commands.append(ProjectCommand(
                    name: target,
                    command: "make \(target)",
                    source: .makefile,
                    detail: detail
                ))
            }
        }
        i += 1
    }
    return commands
}

// MARK: - docker-compose.yml

private func scanDockerCompose(at path: String) -> [ProjectCommand] {
    let dockerComposePath = (path as NSString).appendingPathComponent("docker-compose.yml")
    let dockerComposeAltPath = (path as NSString).appendingPathComponent("docker-compose.yaml")
    let composePath = FileManager.default.fileExists(atPath: dockerComposePath) ? dockerComposePath : dockerComposeAltPath
    guard FileManager.default.fileExists(atPath: composePath),
          let contents = try? String(contentsOfFile: composePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = []
    let lines = contents.components(separatedBy: "\n")
    var inServices = false
    var currentService: String?
    var serviceIndent = 0
    var serviceDetail: [ProjectCommand.DetailItem] = []

    func flushService() {
        if let name = currentService {
            commands.append(ProjectCommand(
                name: name,
                command: "docker compose up \(name)",
                source: .dockerCompose,
                detail: serviceDetail
            ))
        }
        currentService = nil
        serviceDetail = []
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "services:" {
            inServices = true
            continue
        }
        guard inServices else { continue }
        if !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.isEmpty {
            flushService()
            inServices = false
            continue
        }
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        if trimmed.hasSuffix(":"), !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#"), indent <= 4 {
            flushService()
            currentService = String(trimmed.dropLast())
            serviceIndent = indent
        } else if currentService != nil, indent > serviceIndent {
            if trimmed.hasPrefix("image:") {
                serviceDetail.append(.init(label: "Image", value: trimmed.replacingOccurrences(of: "image:", with: "").trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("build:") {
                serviceDetail.append(.init(label: "Build", value: trimmed.replacingOccurrences(of: "build:", with: "").trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("ports:") {
                serviceDetail.append(.init(label: "Ports", value: "defined"))
            } else if trimmed.hasPrefix("- "), serviceDetail.last?.label == "Ports" {
                let port = trimmed.replacingOccurrences(of: "- ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if serviceDetail.last?.value == "defined" {
                    serviceDetail[serviceDetail.count - 1] = .init(label: "Ports", value: port)
                } else {
                    let prev = serviceDetail[serviceDetail.count - 1].value
                    serviceDetail[serviceDetail.count - 1] = .init(label: "Ports", value: "\(prev), \(port)")
                }
            } else if trimmed.hasPrefix("depends_on:") {
                serviceDetail.append(.init(label: "Depends on", value: ""))
            } else if trimmed.hasPrefix("- "), serviceDetail.last?.label == "Depends on" {
                let dep = trimmed.replacingOccurrences(of: "- ", with: "")
                let prev = serviceDetail[serviceDetail.count - 1].value
                serviceDetail[serviceDetail.count - 1] = .init(label: "Depends on", value: prev.isEmpty ? dep : "\(prev), \(dep)")
            }
        }
    }
    flushService()
    return commands
}

// MARK: - justfile

private func scanJustfile(at path: String) -> [ProjectCommand] {
    // justfile can be "justfile" or "Justfile"
    var filePath = (path as NSString).appendingPathComponent("justfile")
    if !FileManager.default.fileExists(atPath: filePath) {
        filePath = (path as NSString).appendingPathComponent("Justfile")
    }
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = []
    let lines = contents.components(separatedBy: "\n")
    var i = 0

    while i < lines.count {
        let line = lines[i]
        // Recipe pattern: name followed by colon (with optional params)
        // e.g. "build:", "test arg:", "deploy target='prod':"
        if let match = line.range(of: #"^([a-zA-Z_][a-zA-Z0-9_-]*)\s*[^:=]*:"#, options: .regularExpression),
           !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
           !line.trimmingCharacters(in: .whitespaces).hasPrefix("set "),
           !line.trimmingCharacters(in: .whitespaces).hasPrefix("export ")
        {
            let matched = String(line[match])
            let name = String(matched.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }))

            var detail: [ProjectCommand.DetailItem] = []
            // Collect recipe body
            var body: [String] = []
            var j = i + 1
            while j < lines.count, lines[j].hasPrefix("    ") || lines[j].hasPrefix("\t") {
                body.append(lines[j].trimmingCharacters(in: .whitespaces))
                j += 1
            }
            if !body.isEmpty {
                detail.append(.init(label: "Recipe", value: body.joined(separator: "\n")))
            }
            // Check for comment above
            if i > 0 {
                let prev = lines[i - 1].trimmingCharacters(in: .whitespaces)
                if prev.hasPrefix("#") {
                    detail.insert(.init(label: "Description", value: String(prev.dropFirst()).trimmingCharacters(in: .whitespaces)), at: 0)
                }
            }

            commands.append(ProjectCommand(
                name: name,
                command: "just \(name)",
                source: .justfile,
                detail: detail
            ))
        }
        i += 1
    }
    return commands
}

// MARK: - pyproject.toml

private func scanPyprojectToml(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("pyproject.toml")
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = []
    let lines = contents.components(separatedBy: "\n")

    // Detect build system for choosing runner
    let hasPoetry = contents.contains("[tool.poetry")
    let hasPdm = contents.contains("[tool.pdm")

    // [project.scripts] — entry points
    if let sectionRange = findTomlSection(named: "project.scripts", in: lines) {
        for i in sectionRange {
            if let (key, value) = parseTomlKeyValue(lines[i]) {
                commands.append(ProjectCommand(
                    name: key,
                    command: key,
                    source: .pyprojectToml,
                    detail: [.init(label: "Entry point", value: value)]
                ))
            }
        }
    }

    // [tool.poetry.scripts]
    if let sectionRange = findTomlSection(named: "tool.poetry.scripts", in: lines) {
        for i in sectionRange {
            if let (key, value) = parseTomlKeyValue(lines[i]) {
                commands.append(ProjectCommand(
                    name: key,
                    command: "poetry run \(key)",
                    source: .pyprojectToml,
                    detail: [.init(label: "Entry point", value: value)]
                ))
            }
        }
    }

    // [tool.hatch.envs.default.scripts] (and other envs)
    for i in 0 ..< lines.count {
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
        if let match = trimmed.range(of: #"^\[tool\.hatch\.envs\.([a-zA-Z0-9_-]+)\.scripts\]"#, options: .regularExpression) {
            let envName = String(trimmed[match]).replacingOccurrences(of: "[tool.hatch.envs.", with: "").replacingOccurrences(of: ".scripts]", with: "")
            var j = i + 1
            while j < lines.count {
                let line = lines[j].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                if line.isEmpty || line.hasPrefix("#") { j += 1; continue }
                if let (key, value) = parseTomlKeyValue(lines[j]) {
                    let cleanValue = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    let cmd = envName == "default" ? "hatch run \(key)" : "hatch run \(envName):\(key)"
                    commands.append(ProjectCommand(
                        name: key,
                        command: cmd,
                        source: .pyprojectToml,
                        detail: [.init(label: "Script", value: cleanValue), .init(label: "Env", value: envName)]
                    ))
                }
                j += 1
            }
        }
    }

    // Also check for Pipfile scripts
    let pipfilePath = (path as NSString).appendingPathComponent("Pipfile")
    if let pipContents = try? String(contentsOfFile: pipfilePath, encoding: .utf8) {
        let pipLines = pipContents.components(separatedBy: "\n")
        if let sectionRange = findTomlSection(named: "scripts", in: pipLines) {
            for i in sectionRange {
                if let (key, value) = parseTomlKeyValue(pipLines[i]) {
                    let cleanValue = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    commands.append(ProjectCommand(
                        name: key,
                        command: "pipenv run \(key)",
                        source: .pyprojectToml,
                        detail: [.init(label: "Script", value: cleanValue)]
                    ))
                }
            }
        }
    }

    // If we found nothing specific, but pyproject.toml exists, add standard commands
    if commands.isEmpty {
        let runner = hasPoetry ? "poetry run" : hasPdm ? "pdm run" : "python -m"
        commands.append(ProjectCommand(
            name: "test",
            command: "\(runner) pytest",
            source: .pyprojectToml,
            detail: [.init(label: "Convention", value: "pytest")]
        ))
    }

    return commands
}

// MARK: - Cargo.toml

private func scanCargoToml(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("Cargo.toml")
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = []
    let lines = contents.components(separatedBy: "\n")

    // Get package name
    var packageName: String?
    if let sectionRange = findTomlSection(named: "package", in: lines) {
        for i in sectionRange {
            if let (key, value) = parseTomlKeyValue(lines[i]), key == "name" {
                packageName = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
    }

    // Standard cargo commands
    commands.append(ProjectCommand(
        name: "build",
        command: "cargo build",
        source: .cargoToml,
        detail: packageName.map { [.init(label: "Package", value: $0)] } ?? []
    ))
    commands.append(ProjectCommand(
        name: "test",
        command: "cargo test",
        source: .cargoToml,
        detail: packageName.map { [.init(label: "Package", value: $0)] } ?? []
    ))
    commands.append(ProjectCommand(
        name: "run",
        command: "cargo run",
        source: .cargoToml,
        detail: packageName.map { [.init(label: "Package", value: $0)] } ?? []
    ))
    commands.append(ProjectCommand(
        name: "clippy",
        command: "cargo clippy",
        source: .cargoToml,
        detail: [.init(label: "Lint", value: "Rust linter")]
    ))

    // [[bin]] targets
    var inBin = false
    var binName: String?
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "[[bin]]" {
            if let name = binName {
                commands.append(ProjectCommand(
                    name: "run \(name)",
                    command: "cargo run --bin \(name)",
                    source: .cargoToml,
                    detail: [.init(label: "Binary target", value: name)]
                ))
            }
            inBin = true
            binName = nil
        } else if trimmed.hasPrefix("[") {
            if let name = binName, inBin {
                commands.append(ProjectCommand(
                    name: "run \(name)",
                    command: "cargo run --bin \(name)",
                    source: .cargoToml,
                    detail: [.init(label: "Binary target", value: name)]
                ))
            }
            inBin = trimmed == "[[bin]]"
            binName = nil
        } else if inBin, let (key, value) = parseTomlKeyValue(line), key == "name" {
            binName = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }
    if let name = binName, inBin {
        commands.append(ProjectCommand(
            name: "run \(name)",
            command: "cargo run --bin \(name)",
            source: .cargoToml,
            detail: [.init(label: "Binary target", value: name)]
        ))
    }

    return commands
}

// MARK: - deno.json / deno.jsonc

private func scanDenoJson(at path: String) -> [ProjectCommand] {
    var filePath = (path as NSString).appendingPathComponent("deno.json")
    if !FileManager.default.fileExists(atPath: filePath) {
        filePath = (path as NSString).appendingPathComponent("deno.jsonc")
    }
    guard let data = FileManager.default.contents(atPath: filePath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tasks = json["tasks"] as? [String: String] else { return [] }

    return tasks.sorted(by: { $0.key < $1.key }).map { name, script in
        ProjectCommand(
            name: name,
            command: "deno task \(name)",
            source: .denoJson,
            detail: [.init(label: "Script", value: script)]
        )
    }
}

// MARK: - composer.json

private func scanComposerJson(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("composer.json")
    guard let data = FileManager.default.contents(atPath: filePath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let scripts = json["scripts"] as? [String: Any] else { return [] }

    return scripts.sorted(by: { $0.key < $1.key }).compactMap { name, value in
        // Skip lifecycle hooks
        let hooks = ["pre-install-cmd", "post-install-cmd", "pre-update-cmd", "post-update-cmd",
                     "pre-autoload-dump", "post-autoload-dump", "pre-package-install", "post-package-install"]
        guard !hooks.contains(name) else { return nil }

        let scriptStr: String
        if let s = value as? String {
            scriptStr = s
        } else if let arr = value as? [String] {
            scriptStr = arr.joined(separator: " && ")
        } else {
            return nil
        }

        return ProjectCommand(
            name: name,
            command: "composer run \(name)",
            source: .composerJson,
            detail: [.init(label: "Script", value: scriptStr)]
        )
    }
}

// MARK: - Rakefile

private func scanRakefile(at path: String) -> [ProjectCommand] {
    var filePath = (path as NSString).appendingPathComponent("Rakefile")
    if !FileManager.default.fileExists(atPath: filePath) {
        filePath = (path as NSString).appendingPathComponent("rakefile")
    }
    if !FileManager.default.fileExists(atPath: filePath) {
        filePath = (path as NSString).appendingPathComponent("Rakefile.rb")
    }
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = []
    let lines = contents.components(separatedBy: "\n")

    for (idx, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Match: task :name or task "name"
        guard let match = trimmed.range(of: #"task\s+[:\"]([a-zA-Z_][a-zA-Z0-9_-]*)"#, options: .regularExpression) else { continue }
        let segment = String(trimmed[match])
        let name = segment
            .replacingOccurrences(of: "task", with: "")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":\"'"))

        var detail: [ProjectCommand.DetailItem] = []
        // Check for desc/description above
        if idx > 0 {
            let prev = lines[idx - 1].trimmingCharacters(in: .whitespaces)
            if prev.hasPrefix("desc ") || prev.hasPrefix("description ") {
                let desc = prev
                    .replacingOccurrences(of: "desc ", with: "")
                    .replacingOccurrences(of: "description ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                detail.append(.init(label: "Description", value: desc))
            }
        }

        commands.append(ProjectCommand(
            name: name,
            command: "rake \(name)",
            source: .rakefile,
            detail: detail
        ))
    }
    return commands
}

// MARK: - Procfile

private func scanProcfile(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("Procfile")
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    return contents.components(separatedBy: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[trimmed.startIndex ..< colonIdx]).trimmingCharacters(in: .whitespaces)
        let command = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !command.isEmpty else { return nil }

        return ProjectCommand(
            name: name,
            command: command,
            source: .procfile,
            detail: [.init(label: "Process", value: command)]
        )
    }
}

// MARK: - Taskfile.yml

private func scanTaskfileYml(at path: String) -> [ProjectCommand] {
    var filePath = (path as NSString).appendingPathComponent("Taskfile.yml")
    if !FileManager.default.fileExists(atPath: filePath) {
        filePath = (path as NSString).appendingPathComponent("Taskfile.yaml")
    }
    if !FileManager.default.fileExists(atPath: filePath) {
        filePath = (path as NSString).appendingPathComponent("taskfile.yml")
    }
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = []
    let lines = contents.components(separatedBy: "\n")
    var inTasks = false
    var taskIndent = 0
    var currentTask: String?
    var taskDesc: String?
    var taskCmds: [String] = []

    func flushTask() {
        if let name = currentTask {
            var detail: [ProjectCommand.DetailItem] = []
            if let desc = taskDesc {
                detail.append(.init(label: "Description", value: desc))
            }
            if !taskCmds.isEmpty {
                detail.append(.init(label: "Commands", value: taskCmds.joined(separator: "\n")))
            }
            commands.append(ProjectCommand(
                name: name,
                command: "task \(name)",
                source: .taskfileYml,
                detail: detail
            ))
        }
        currentTask = nil
        taskDesc = nil
        taskCmds = []
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "tasks:" {
            inTasks = true
            taskIndent = line.prefix(while: { $0 == " " }).count + 2
            continue
        }
        guard inTasks else { continue }
        if !line.hasPrefix(" "), !line.isEmpty, !trimmed.isEmpty {
            flushTask()
            inTasks = false
            continue
        }
        let indent = line.prefix(while: { $0 == " " }).count
        if indent == taskIndent, trimmed.hasSuffix(":"), !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#") {
            flushTask()
            currentTask = String(trimmed.dropLast())
        } else if currentTask != nil, indent > taskIndent {
            if trimmed.hasPrefix("desc:") {
                taskDesc = trimmed.replacingOccurrences(of: "desc:", with: "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if trimmed.hasPrefix("- ") {
                taskCmds.append(trimmed.replacingOccurrences(of: "- ", with: ""))
            }
        }
    }
    flushTask()
    return commands
}

// MARK: - go.mod

private func scanGoMod(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("go.mod")
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var moduleName: String?
    for line in contents.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("module ") {
            moduleName = String(trimmed.dropFirst("module ".count)).trimmingCharacters(in: .whitespaces)
            break
        }
    }

    var commands: [ProjectCommand] = []
    let detail: [ProjectCommand.DetailItem] = moduleName.map { [.init(label: "Module", value: $0)] } ?? []

    commands.append(ProjectCommand(name: "build", command: "go build ./...", source: .goMod, detail: detail))
    commands.append(ProjectCommand(name: "test", command: "go test ./...", source: .goMod, detail: detail))
    commands.append(ProjectCommand(name: "run", command: "go run .", source: .goMod, detail: detail))
    commands.append(ProjectCommand(name: "vet", command: "go vet ./...", source: .goMod, detail: detail))

    // Check for mage
    let magePath = (path as NSString).appendingPathComponent("magefile.go")
    if FileManager.default.fileExists(atPath: magePath),
       let mageContents = try? String(contentsOfFile: magePath, encoding: .utf8)
    {
        let mageLines = mageContents.components(separatedBy: "\n")
        for line in mageLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.range(of: #"^func\s+([A-Z][a-zA-Z0-9]*)\s*\("#, options: .regularExpression) {
                let funcDecl = String(trimmed[match])
                let name = funcDecl
                    .replacingOccurrences(of: "func ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let parenIdx = name.firstIndex(of: "(")!
                let funcName = String(name[name.startIndex ..< parenIdx])
                commands.append(ProjectCommand(
                    name: funcName.lowercased(),
                    command: "mage \(funcName)",
                    source: .goMod,
                    detail: [.init(label: "Mage target", value: funcName)]
                ))
            }
        }
    }

    return commands
}

// MARK: - Package.swift

private func scanSwiftPackage(at path: String) -> [ProjectCommand] {
    let filePath = (path as NSString).appendingPathComponent("Package.swift")
    guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

    var commands: [ProjectCommand] = [
        ProjectCommand(name: "build", command: "swift build", source: .swiftPackage),
        ProjectCommand(name: "test", command: "swift test", source: .swiftPackage)
    ]

    // Find executable targets: .executableTarget(name: "Foo"
    let pattern = #"\.executableTarget\(\s*name:\s*"([^"]+)""#
    if let regex = try? NSRegularExpression(pattern: pattern) {
        let range = NSRange(contents.startIndex..., in: contents)
        for match in regex.matches(in: contents, range: range) {
            if let nameRange = Range(match.range(at: 1), in: contents) {
                let targetName = String(contents[nameRange])
                commands.append(ProjectCommand(
                    name: "run \(targetName)",
                    command: "swift run \(targetName)",
                    source: .swiftPackage,
                    detail: [.init(label: "Executable target", value: targetName)]
                ))
            }
        }
    }

    return commands
}

// MARK: - Xcode project

private func scanXcodeproj(at path: String) -> [ProjectCommand] {
    // Find *.xcodeproj in the directory
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
    guard let xcodeproj = entries.first(where: { $0.hasSuffix(".xcodeproj") }) else { return [] }

    // Also skip if Package.swift exists (SPM project, already covered)
    let hasPackageSwift = FileManager.default.fileExists(
        atPath: (path as NSString).appendingPathComponent("Package.swift")
    )
    if hasPackageSwift { return [] }

    var commands: [ProjectCommand] = []
    let projName = (xcodeproj as NSString).deletingPathExtension

    // Try to list schemes via xcodebuild -list (fast, cached)
    // Fall back to just offering build/test with the project name
    commands.append(ProjectCommand(
        name: "build",
        command: "xcodebuild -project \(xcodeproj) -scheme \(projName) build",
        source: .xcodeproj,
        detail: [.init(label: "Project", value: projName)]
    ))
    commands.append(ProjectCommand(
        name: "test",
        command: "xcodebuild -project \(xcodeproj) -scheme \(projName) test",
        source: .xcodeproj,
        detail: [.init(label: "Project", value: projName)]
    ))

    return commands
}

// MARK: - TOML Helpers

private func findTomlSection(named name: String, in lines: [String]) -> Range<Int>? {
    let header = "[\(name)]"
    guard let startIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
        return nil
    }
    let bodyStart = startIdx + 1
    var end = bodyStart
    while end < lines.count {
        let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") { break }
        end += 1
    }
    return bodyStart ..< end
}

private func parseTomlKeyValue(_ line: String) -> (String, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("[") else { return nil }
    guard let eqIdx = trimmed.firstIndex(of: "=") else { return nil }
    let key = String(trimmed[trimmed.startIndex ..< eqIdx]).trimmingCharacters(in: .whitespaces)
    let value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (key, value)
}

// MARK: - Dedup

private func dedupeCommands(_ commands: [ProjectCommand]) -> [ProjectCommand] {
    var seen = Set<String>()
    return commands.filter { command in
        let key = command.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if seen.contains(key) { return false }
        seen.insert(key)
        return true
    }
}
