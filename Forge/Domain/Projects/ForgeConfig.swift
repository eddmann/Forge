import Foundation

// MARK: - ForgeConfig (forge.json)

/// Project-level configuration loaded from `forge.json` in the project root.
/// All fields are optional — a missing file or empty object produces default behaviour.
struct ForgeConfig: Codable {
    var ports: [String: PortConfig]?
    var compose: ComposeConfig?
    var processes: [String: ProcessConfig]?
    var commands: [String: CommandConfig]?
    var workspace: WorkspaceLifecycle?

    static func load(from projectPath: String) -> ForgeConfig? {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent("forge.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ForgeConfig.self, from: data)
    }
}

// MARK: - Port

/// Port configuration. Decodes from either a port number or a full object.
enum PortConfig: Codable {
    case simple(Int)
    case full(PortFullConfig)

    var port: Int {
        switch self {
        case let .simple(port): port
        case let .full(config): config.port
        }
    }

    var detail: String? {
        switch self {
        case .simple: nil
        case let .full(config): config.detail
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let port = try? container.decode(Int.self) {
            self = .simple(port)
        } else {
            self = try .full(PortFullConfig(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .simple(port):
            var container = encoder.singleValueContainer()
            try container.encode(port)
        case let .full(config):
            try config.encode(to: encoder)
        }
    }
}

struct PortFullConfig: Codable {
    var port: Int
    var detail: String?
}

// MARK: - Compose

/// Docker Compose configuration. Decodes from either a string path or a full object.
enum ComposeConfig: Codable {
    case simple(String)
    case full(ComposeFullConfig)

    var file: String {
        switch self {
        case let .simple(path): path
        case let .full(config): config.file
        }
    }

    var autoStart: Bool {
        switch self {
        case .simple: true
        case let .full(config): config.autoStart
        }
    }

    var services: [String]? {
        switch self {
        case .simple: nil
        case let .full(config): config.services
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let path = try? container.decode(String.self) {
            self = .simple(path)
        } else {
            self = try .full(ComposeFullConfig(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .simple(path):
            var container = encoder.singleValueContainer()
            try container.encode(path)
        case let .full(config):
            try config.encode(to: encoder)
        }
    }
}

struct ComposeFullConfig: Codable {
    var file: String
    var autoStart: Bool
    var services: [String]?

    init(file: String, autoStart: Bool = true, services: [String]? = nil) {
        self.file = file
        self.autoStart = autoStart
        self.services = services
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decode(String.self, forKey: .file)
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? true
        services = try container.decodeIfPresent([String].self, forKey: .services)
    }
}

// MARK: - Process

/// Process configuration. Decodes from either a command string or a full object.
enum ProcessConfig: Codable {
    case simple(String)
    case full(ProcessFullConfig)

    var command: String {
        switch self {
        case let .simple(cmd): cmd
        case let .full(config): config.command
        }
    }

    var dir: String? {
        switch self {
        case .simple: nil
        case let .full(config): config.dir
        }
    }

    var autoStart: Bool {
        switch self {
        case .simple: false
        case let .full(config): config.autoStart
        }
    }

    var autoRestart: Bool {
        switch self {
        case .simple: false
        case let .full(config): config.autoRestart
        }
    }

    var env: [String: String]? {
        switch self {
        case .simple: nil
        case let .full(config): config.env
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let cmd = try? container.decode(String.self) {
            self = .simple(cmd)
        } else {
            self = try .full(ProcessFullConfig(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .simple(cmd):
            var container = encoder.singleValueContainer()
            try container.encode(cmd)
        case let .full(config):
            try config.encode(to: encoder)
        }
    }
}

struct ProcessFullConfig: Codable {
    var command: String
    var dir: String?
    var autoStart: Bool
    var autoRestart: Bool
    var env: [String: String]?

    init(
        command: String,
        dir: String? = nil,
        autoStart: Bool = false,
        autoRestart: Bool = false,
        env: [String: String]? = nil
    ) {
        self.command = command
        self.dir = dir
        self.autoStart = autoStart
        self.autoRestart = autoRestart
        self.env = env
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        dir = try container.decodeIfPresent(String.self, forKey: .dir)
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        autoRestart = try container.decodeIfPresent(Bool.self, forKey: .autoRestart) ?? false
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
    }
}

// MARK: - Command

/// Command configuration. Decodes from either a command string or a full object.
enum CommandConfig: Codable {
    case simple(String)
    case full(CommandFullConfig)

    var command: String {
        switch self {
        case let .simple(cmd): cmd
        case let .full(config): config.command
        }
    }

    var detail: String? {
        switch self {
        case .simple: nil
        case let .full(config): config.detail
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let cmd = try? container.decode(String.self) {
            self = .simple(cmd)
        } else {
            self = try .full(CommandFullConfig(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .simple(cmd):
            var container = encoder.singleValueContainer()
            try container.encode(cmd)
        case let .full(config):
            try config.encode(to: encoder)
        }
    }
}

struct CommandFullConfig: Codable {
    var command: String
    var detail: String?
}

// MARK: - Workspace Lifecycle

struct WorkspaceLifecycle: Codable {
    var setup: ScriptConfig?
    var teardown: ScriptConfig?
}

/// Script configuration. Decodes from either a single command string or an array of commands.
enum ScriptConfig: Codable {
    case single(String)
    case multiple([String])

    var commands: [String] {
        switch self {
        case let .single(cmd): [cmd]
        case let .multiple(cmds): cmds
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let cmd = try? container.decode(String.self) {
            self = .single(cmd)
        } else {
            self = try .multiple(container.decode([String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .single(cmd):
            try container.encode(cmd)
        case let .multiple(cmds):
            try container.encode(cmds)
        }
    }
}
