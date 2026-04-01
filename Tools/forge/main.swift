import Foundation

// MARK: - Forge CLI

// Usage: forge notify <title> <body>

let args = CommandLine.arguments

guard args.count >= 2 else {
    printUsage()
    exit(1)
}

switch args[1] {
case "notify":
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("Usage: forge notify <title> <body>\n".utf8))
        exit(1)
    }
    let title = args[2]
    let body = args[3]
    sendNotify(title: title, body: body)

case "--help", "-h", "help":
    printUsage()
    exit(0)

default:
    FileHandle.standardError.write(Data("Unknown command: \(args[1])\n".utf8))
    printUsage()
    exit(1)
}

// MARK: - Notify

func sendNotify(title: String, body: String) {
    let socketPath = ProcessInfo.processInfo.environment["FORGE_SOCKET"]
        ?? NSHomeDirectory() + "/.forge/state/forge.sock"
    let sessionID = ProcessInfo.processInfo.environment["FORGE_SESSION"]

    // Build JSON payload
    var payload: [String: String] = [
        "command": "notify",
        "title": title,
        "body": body
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
        FileHandle.standardError.write(Data("Failed to connect to Forge socket at \(socketPath)\n".utf8))
        exit(1)
    }

    // Send JSON + newline
    json.withCString { ptr in
        _ = Darwin.write(fd, ptr, strlen(ptr))
    }
}

// MARK: - Help

func printUsage() {
    let usage = """
    Usage: forge <command> [arguments]

    Commands:
      notify <title> <body>    Send a notification to Forge

    Environment:
      FORGE_SOCKET    Path to Forge socket (default: ~/.forge/state/forge.sock)
      FORGE_SESSION   Terminal session UUID (auto-set by Forge)

    Examples:
      forge notify "Claude Code" "status:running"
      forge notify "Claude Code" "Task complete"
      forge notify "Codex" "status:waiting"

    """
    FileHandle.standardError.write(Data(usage.utf8))
}
