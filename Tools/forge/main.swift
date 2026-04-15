import Foundation

// MARK: - Forge CLI

// Usage: forge event <agent> <event_type>
// Reads JSON from stdin, wraps with metadata, sends to Forge socket.

let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let subargs = Array(args.dropFirst(2))

switch args[1] {
// Universal escape hatch
case "rpc":
    guard let method = subargs.first else {
        FileHandle.standardError.write(Data("Usage: forge rpc <method> [json-params]\n".utf8))
        exit(1)
    }
    sendRPC(method: method, paramsJSON: subargs.count >= 2 ? subargs[1] : nil)

// Sugar subcommands (system.*)
case "ping":
    callMethod("system.ping", params: [:])

case "identify":
    callMethod("system.identify", params: identifyParams(from: subargs))

case "capabilities":
    callMethod("system.capabilities", params: [:])

// Sugar (app.*)
case "notify":
    callMethod("app.notify", params: parseNotifyArgs(subargs))

case "tree":
    var params: [String: Any] = [:]
    if let ws = optionValue(subargs, "--workspace") { params["workspace_id"] = ws }
    callMethod("app.tree", params: params)

case "log":
    callMethod("app.log", params: parseLogArgs(subargs))

// Sugar (workspace.*)
case "workspace":
    dispatchWorkspace(subargs)

// Sugar (terminal.*)
case "terminal":
    dispatchTerminal(subargs)

// Sugar (agent.*)
case "agent":
    dispatchAgent(subargs)

case "--help", "-h", "help":
    printUsage()
    exit(0)

default:
    FileHandle.standardError.write(Data("Unknown command: \(args[1])\n".utf8))
    printUsage()
    exit(1)
}

// MARK: - RPC

/// Send a JSON-RPC request and write the response (or error) to stdout.
/// Exits non-zero on RPC error or transport failure so scripts can branch.
func sendRPC(method: String, paramsJSON: String?) {
    let socketPath = ProcessInfo.processInfo.environment["FORGE_SOCKET"]
        ?? NSHomeDirectory() + "/.forge/state/forge.sock"

    var envelope: [String: Any] = ["method": method]
    if let paramsJSON, !paramsJSON.isEmpty {
        guard let data = paramsJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else {
            FileHandle.standardError.write(Data("Invalid JSON in params\n".utf8))
            exit(1)
        }
        envelope["params"] = parsed
    }

    guard let requestData = try? JSONSerialization.data(withJSONObject: envelope),
          var requestLine = String(data: requestData, encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("Failed to encode request\n".utf8))
        exit(1)
    }
    requestLine += "\n"

    guard let responseLine = sendAndReceive(requestLine, socketPath: socketPath) else {
        FileHandle.standardError.write(Data("No response from Forge (is it running?)\n".utf8))
        exit(1)
    }

    // Print response as-is (already JSON) and set exit code from "ok" field.
    FileHandle.standardOutput.write(Data((responseLine + "\n").utf8))

    if let data = responseLine.data(using: .utf8),
       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       (dict["ok"] as? Bool) == false
    {
        exit(1)
    }
}

// MARK: - Socket

/// Write a request, read a single newline-terminated response. Returns nil on
/// transport failure (e.g. Forge not running).
func sendAndReceive(_ message: String, socketPath: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for i in 0 ..< min(pathBytes.count, maxLen - 1) {
            buf[i] = UInt8(bitPattern: pathBytes[i])
        }
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else { return nil }

    // 5 second read timeout
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    message.withCString { ptr in
        _ = Darwin.write(fd, ptr, strlen(ptr))
    }

    var buffer = [UInt8](repeating: 0, count: 131_072)
    var accumulated = Data()
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        accumulated.append(buffer, count: n)
        if accumulated.contains(0x0A) { break }
        if accumulated.count > 131_072 { break }
    }

    return String(data: accumulated, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Help

func printUsage() {
    let usage = """
    Usage: forge <command> [arguments]

    System:
      ping                              Health check
      identify                          Resolve current session/workspace/project
      capabilities                      List all supported RPC methods

    App:
      notify --title T [--body B] [--subtitle S]   Fire a user notification
      tree [--workspace ID]                        Dump UI topology as JSON
      log <message> [--level info|warn|error]      Append to workspace activity log

    Workspace:
      workspace list [--project ID]     List workspaces
      workspace current                 Show the active workspace
      workspace select <id>             Switch to a workspace

    Terminal:
      terminal list [--workspace ID]              List sessions
      terminal read [--lines N]                   Capture scrollback
      terminal send <text>                        Type text into a session
      terminal send-key <key>                     Send a key (Return, Ctrl-C, ...)
      terminal open-agent <command>               Spawn a new agent tab

    Agent:
      agent event <agent> <event_type>            Forward hook event (reads JSON stdin)

    Advanced:
      rpc <method> [json-params]        Invoke any RPC method directly

    Environment (auto-set by Forge in spawned shells):
      FORGE_SOCKET         Path to Forge socket
      FORGE_SESSION        Terminal session UUID (used by terminal/agent commands)
      FORGE_WORKSPACE_ID   Active workspace UUID
      FORGE_PROJECT_ID     Active project UUID

    Global flags (where meaningful):
      --session ID --workspace ID --project ID    Override env-var scope

    """
    FileHandle.standardError.write(Data(usage.utf8))
}
