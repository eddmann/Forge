import Foundation

// MARK: - Forge CLI

// Usage: forge event <agent> <event_type>
// Reads JSON from stdin, wraps with metadata, sends to Forge socket.

let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(1)
}

switch args[1] {
case "event":
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("Usage: forge event <agent> <event_type>\n".utf8))
        exit(1)
    }
    let agent = args[2]
    let eventType = args[3]
    sendEvent(agent: agent, eventType: eventType)

case "open-agent":
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("Usage: forge open-agent <agent-command>\n".utf8))
        exit(1)
    }
    openAgent(command: args[2])

case "rpc":
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("Usage: forge rpc <method> [json-params]\n".utf8))
        exit(1)
    }
    let method = args[2]
    let paramsArg: String? = args.count >= 4 ? args[3] : nil
    sendRPC(method: method, paramsJSON: paramsArg)

case "--help", "-h", "help":
    printUsage()
    exit(0)

default:
    FileHandle.standardError.write(Data("Unknown command: \(args[1])\n".utf8))
    printUsage()
    exit(1)
}

// MARK: - Event

func sendEvent(agent: String, eventType: String) {
    let socketPath = ProcessInfo.processInfo.environment["FORGE_SOCKET"]
        ?? NSHomeDirectory() + "/.forge/state/forge.sock"
    let sessionID = ProcessInfo.processInfo.environment["FORGE_SESSION"]

    // Read hook JSON payload from stdin
    var stdinData = Data()
    let handle = FileHandle.standardInput
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        stdinData.append(chunk)
        if stdinData.count > 131_072 { break } // 128KB limit
    }

    // Build wrapped payload
    var payload: [String: Any] = [
        "command": "agent_event",
        "agent": agent,
        "event": eventType
    ]
    if let sessionID {
        payload["session"] = sessionID
    }

    // Parse stdin as JSON and attach as "data" field
    if !stdinData.isEmpty,
       let stdinJSON = try? JSONSerialization.jsonObject(with: stdinData)
    {
        payload["data"] = stdinJSON
    }

    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          var json = String(data: data, encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("Failed to encode JSON\n".utf8))
        exit(1)
    }
    json += "\n"

    sendToSocket(json, socketPath: socketPath)
}

// MARK: - Open Agent

func openAgent(command: String) {
    let socketPath = ProcessInfo.processInfo.environment["FORGE_SOCKET"]
        ?? NSHomeDirectory() + "/.forge/state/forge.sock"
    let sessionID = ProcessInfo.processInfo.environment["FORGE_SESSION"]

    var payload: [String: Any] = [
        "command": "open_agent",
        "agent_command": command
    ]
    if let sessionID {
        payload["session"] = sessionID
    }

    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          var json = String(data: data, encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("Failed to encode JSON\n".utf8))
        exit(1)
    }
    json += "\n"

    sendToSocket(json, socketPath: socketPath)
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

/// Fire-and-forget write. Used by hook events that don't need a response.
func sendToSocket(_ message: String, socketPath: String) {
    let fd = openSocket(socketPath: socketPath)
    defer { close(fd) }
    message.withCString { ptr in
        _ = Darwin.write(fd, ptr, strlen(ptr))
    }
}

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

private func openSocket(socketPath: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        FileHandle.standardError.write(Data("Failed to create socket\n".utf8))
        exit(1)
    }

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
    guard connectResult == 0 else {
        // Silent failure — don't break agent hooks if Forge isn't running
        exit(0)
    }
    return fd
}

// MARK: - Help

func printUsage() {
    let usage = """
    Usage: forge <command> [arguments]

    Commands:
      event <agent> <event_type>    Pipe agent hook JSON from stdin to Forge
      open-agent <agent-command>    Open a new agent tab in Forge
      rpc <method> [json-params]    Invoke a JSON-RPC method directly

    Environment:
      FORGE_SOCKET    Path to Forge socket (default: ~/.forge/state/forge.sock)
      FORGE_SESSION   Terminal session UUID (auto-set by Forge)

    Examples:
      echo '{"tool_name":"Bash"}' | forge event claude tool_start
      forge open-agent claude
      forge rpc system.ping
      forge rpc system.identify '{"workspace_id":"..."}'

    """
    FileHandle.standardError.write(Data(usage.utf8))
}
