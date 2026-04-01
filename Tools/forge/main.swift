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
        if stdinData.count > 131072 { break } // 128KB limit
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
       let stdinJSON = try? JSONSerialization.jsonObject(with: stdinData) {
        payload["data"] = stdinJSON
    }

    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          var json = String(data: data, encoding: .utf8)
    else {
        FileHandle.standardError.write(Data("Failed to encode JSON\n".utf8))
        exit(1)
    }
    json += "\n"

    // Connect to Unix socket
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        FileHandle.standardError.write(Data("Failed to create socket\n".utf8))
        exit(1)
    }
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
    guard connectResult == 0 else {
        // Silent failure — don't break agent hooks if Forge isn't running
        exit(0)
    }

    json.withCString { ptr in
        _ = Darwin.write(fd, ptr, strlen(ptr))
    }
}

// MARK: - Help

func printUsage() {
    let usage = """
    Usage: forge <command> [arguments]

    Commands:
      event <agent> <event_type>    Pipe agent hook JSON from stdin to Forge

    Environment:
      FORGE_SOCKET    Path to Forge socket (default: ~/.forge/state/forge.sock)
      FORGE_SESSION   Terminal session UUID (auto-set by Forge)

    Examples:
      echo '{"tool_name":"Bash"}' | forge event claude tool_start
      forge event codex stop < /dev/stdin

    """
    FileHandle.standardError.write(Data(usage.utf8))
}
