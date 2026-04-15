import Foundation

// MARK: - Common

/// Run an RPC method with a typed params dict. Same exit-code behaviour as
/// `forge rpc`: 1 if the response has `"ok": false`, 0 otherwise.
func callMethod(_ method: String, params: [String: Any]) {
    let json: String?
    if params.isEmpty {
        json = nil
    } else {
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let s = String(data: data, encoding: .utf8)
        else {
            FileHandle.standardError.write(Data("Failed to encode params\n".utf8))
            exit(2)
        }
        json = s
    }
    sendRPC(method: method, paramsJSON: json)
}

/// Extract `--flag value` from an argument list; returns the value or nil.
func optionValue(_ args: [String], _ flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

/// Extract `--flag` without a value; returns true if present.
func hasFlag(_ args: [String], _ flag: String) -> Bool {
    args.contains(flag)
}

/// Build scope params from global flags, falling back to env vars.
func scopeParams(_ args: [String]) -> [String: Any] {
    var params: [String: Any] = [:]
    if let s = optionValue(args, "--session") ?? ProcessInfo.processInfo.environment["FORGE_SESSION"] {
        params["session_id"] = s
    }
    if let w = optionValue(args, "--workspace") ?? ProcessInfo.processInfo.environment["FORGE_WORKSPACE_ID"] {
        params["workspace_id"] = w
    }
    if let p = optionValue(args, "--project") ?? ProcessInfo.processInfo.environment["FORGE_PROJECT_ID"] {
        params["project_id"] = p
    }
    return params
}

/// First non-flag argument (i.e. not starting with `-` and not the value of a `--flag`).
func firstPositional(_ args: [String]) -> String? {
    var skipNext = false
    for a in args {
        if skipNext { skipNext = false; continue }
        if a.hasPrefix("--") { skipNext = true; continue }
        return a
    }
    return nil
}

// MARK: - system.identify

func identifyParams(from args: [String]) -> [String: Any] {
    scopeParams(args)
}

// MARK: - app.notify / app.log

func parseNotifyArgs(_ args: [String]) -> [String: Any] {
    var params: [String: Any] = [:]
    if let title = optionValue(args, "--title") {
        params["title"] = title
    } else {
        FileHandle.standardError.write(Data("notify requires --title\n".utf8))
        exit(2)
    }
    if let subtitle = optionValue(args, "--subtitle") { params["subtitle"] = subtitle }
    if let body = optionValue(args, "--body") { params["body"] = body }
    return params
}

func parseLogArgs(_ args: [String]) -> [String: Any] {
    guard let message = firstPositional(args) else {
        FileHandle.standardError.write(Data("Usage: forge log <message> [--level info|warn|error] [--workspace ID]\n".utf8))
        exit(2)
    }
    var params: [String: Any] = ["message": message]
    if let level = optionValue(args, "--level") { params["level"] = level }
    if let ws = optionValue(args, "--workspace") ?? ProcessInfo.processInfo.environment["FORGE_WORKSPACE_ID"] {
        params["workspace_id"] = ws
    }
    return params
}

// MARK: - workspace.*

func dispatchWorkspace(_ args: [String]) {
    guard let sub = args.first else {
        FileHandle.standardError.write(Data("Usage: forge workspace <list|current|select> [args]\n".utf8))
        exit(2)
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":
        var params: [String: Any] = [:]
        if let pid = optionValue(rest, "--project") ?? ProcessInfo.processInfo.environment["FORGE_PROJECT_ID"] {
            params["project_id"] = pid
        }
        callMethod("workspace.list", params: params)
    case "current":
        callMethod("workspace.current", params: [:])
    case "select":
        guard let id = firstPositional(rest) else {
            FileHandle.standardError.write(Data("Usage: forge workspace select <workspace-id>\n".utf8))
            exit(2)
        }
        callMethod("workspace.select", params: ["workspace_id": id])
    default:
        FileHandle.standardError.write(Data("Unknown workspace subcommand: \(sub)\n".utf8))
        exit(2)
    }
}

// MARK: - terminal.*

func dispatchTerminal(_ args: [String]) {
    guard let sub = args.first else {
        FileHandle.standardError.write(Data("Usage: forge terminal <list|read|send|send-key|open-agent> [args]\n".utf8))
        exit(2)
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":
        var params: [String: Any] = [:]
        if let ws = optionValue(rest, "--workspace") ?? ProcessInfo.processInfo.environment["FORGE_WORKSPACE_ID"] {
            params["workspace_id"] = ws
        }
        callMethod("terminal.list", params: params)

    case "read":
        var params = scopeParams(rest)
        if params["session_id"] == nil {
            FileHandle.standardError.write(Data("terminal read requires --session or $FORGE_SESSION\n".utf8))
            exit(2)
        }
        if let linesArg = optionValue(rest, "--lines"), let n = Int(linesArg) {
            params["lines"] = n
        }
        callMethod("terminal.read_screen", params: params)

    case "send":
        guard let text = firstPositional(rest) else {
            FileHandle.standardError.write(Data("Usage: forge terminal send <text> [--session ID]\n".utf8))
            exit(2)
        }
        var params = scopeParams(rest)
        params["text"] = text
        if params["session_id"] == nil {
            FileHandle.standardError.write(Data("terminal send requires --session or $FORGE_SESSION\n".utf8))
            exit(2)
        }
        callMethod("terminal.send_text", params: params)

    case "send-key":
        guard let key = firstPositional(rest) else {
            FileHandle.standardError.write(Data("Usage: forge terminal send-key <key> [--session ID]\n".utf8))
            exit(2)
        }
        var params = scopeParams(rest)
        params["key"] = key
        if params["session_id"] == nil {
            FileHandle.standardError.write(Data("terminal send-key requires --session or $FORGE_SESSION\n".utf8))
            exit(2)
        }
        callMethod("terminal.send_key", params: params)

    case "open-agent":
        guard let cmd = firstPositional(rest) else {
            FileHandle.standardError.write(Data("Usage: forge terminal open-agent <agent-command>\n".utf8))
            exit(2)
        }
        callMethod("terminal.open_agent", params: ["agent_command": cmd])

    default:
        FileHandle.standardError.write(Data("Unknown terminal subcommand: \(sub)\n".utf8))
        exit(2)
    }
}

// MARK: - agent.*

func dispatchAgent(_ args: [String]) {
    guard let sub = args.first else {
        FileHandle.standardError.write(Data("Usage: forge agent event <agent> <event_type>\n".utf8))
        exit(2)
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "event":
        // `forge agent event <agent> <event_type>` — hook forwarder used by the
        // Claude / Codex hook scripts. Reads optional JSON from stdin and
        // attaches it as `data`.
        guard rest.count >= 2 else {
            FileHandle.standardError.write(Data("Usage: forge agent event <agent> <event_type>\n".utf8))
            exit(2)
        }
        var params: [String: Any] = ["agent": rest[0], "event": rest[1]]
        if let sid = ProcessInfo.processInfo.environment["FORGE_SESSION"] {
            params["session_id"] = sid
        }
        var stdinData = Data()
        let handle = FileHandle.standardInput
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            stdinData.append(chunk)
            if stdinData.count > 131_072 { break }
        }
        if !stdinData.isEmpty,
           let parsed = try? JSONSerialization.jsonObject(with: stdinData)
        {
            params["data"] = parsed
        }
        callMethod("agent.event", params: params)

    default:
        FileHandle.standardError.write(Data("Unknown agent subcommand: \(sub)\n".utf8))
        exit(2)
    }
}
