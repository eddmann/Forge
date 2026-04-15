import Foundation

final class ForgeSocketServer {
    static let shared = ForgeSocketServer()

    private let socketPath: String
    private var serverFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.forge.socket-server", qos: .utility)

    private init() {
        socketPath = ForgeStore.shared.stateDir
            .appendingPathComponent(ForgeStore.socketName).path
    }

    // MARK: - Lifecycle

    func start() {
        let dir = (socketPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        // Clean up stale socket
        if fm.fileExists(atPath: socketPath) {
            if isStaleSocket() {
                unlink(socketPath)
            } else {
                return
            }
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for i in 0 ..< min(pathBytes.count, maxLen - 1) {
                buf[i] = UInt8(bitPattern: pathBytes[i])
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult >= 0 else {
            close(fd)
            return
        }

        // Set socket file permissions
        chmod(socketPath, 0o600)

        guard listen(fd, 16) >= 0 else {
            close(fd)
            unlink(socketPath)
            return
        }

        serverFD = fd

        // Register cleanup
        atexit {
            ForgeSocketServer.shared.stop()
        }

        // Start accept loop
        queue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let fd = serverFD
        serverFD = -1
        if fd >= 0 {
            close(fd)
        }
        unlink(socketPath)
    }

    // MARK: - Accept Loop

    private func acceptLoop() {
        while serverFD >= 0 {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverFD, sockPtr, &clientLen)
                }
            }

            guard clientFD >= 0 else {
                if serverFD < 0 { break } // Server was stopped
                if errno == EINTR { continue }
                break
            }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    // MARK: - Client Handler

    private func handleClient(_ fd: Int32) {
        // Set read timeout (5 seconds)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 131_072)
        var accumulated = Data()

        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            accumulated.append(buffer, count: bytesRead)

            // Check for newline delimiter
            if accumulated.contains(0x0A) { break }

            // Prevent oversized messages
            if accumulated.count > 131_072 {
                close(fd)
                return
            }
        }

        guard !accumulated.isEmpty,
              let line = String(data: accumulated, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty,
              let data = line.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            close(fd)
            return
        }

        // Hand the fd off to an async Task so the worker thread is freed
        // immediately. The Task hops to MainActor inside `ForgeRPC.dispatch`,
        // writes the response, and closes the fd.
        Task {
            let response = await ForgeRPC.dispatch(envelope: dict)
            Self.writeResponse(response, to: fd)
            close(fd)
        }
    }

    private static func writeResponse(_ response: [String: Any], to fd: Int32) {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line += "\n"
        line.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
    }

    // MARK: - Helpers

    /// Check if an existing socket file is stale (no server listening).
    private func isStaleSocket() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
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

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        // If connect succeeds, another instance is listening — not stale
        // If connect fails, the socket is stale
        return result != 0
    }
}
