import Foundation

/// Debug logger for agent events. Writes JSONL to ~/.forge/logs/agent-events-{date}.jsonl.
/// Disabled by default — toggle via ForgeStore settings.
class AgentEventLogger {
    static let shared = AgentEventLogger()

    var enabled: Bool = false

    private let queue = DispatchQueue(label: "com.forge.agent-event-logger", qos: .utility)
    private let logDir: String
    private var currentDate: String = ""
    private var fileHandle: FileHandle?

    private init() {
        logDir = NSHomeDirectory() + "/\(ForgeStore.forgeDirName)/logs"
    }

    func log(source: String, session: UUID?, agent: String?, event: String, data: [String: Any]?) {
        guard enabled else { return }

        var entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "source": source,
            "event": event
        ]
        if let session { entry["session"] = session.uuidString }
        if let agent { entry["agent"] = agent }
        if let data { entry["data"] = data }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: jsonData, encoding: .utf8)
        else { return }
        line += "\n"

        queue.async { [weak self] in
            self?.writeLine(line)
        }
    }

    private func writeLine(_ line: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logDir) {
            try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let dateStr = Self.dateString()
        if dateStr != currentDate {
            fileHandle?.closeFile()
            fileHandle = nil
            currentDate = dateStr
            cleanOldLogs()
        }

        let path = (logDir as NSString).appendingPathComponent("agent-events-\(currentDate).jsonl")

        if fileHandle == nil {
            if !fm.fileExists(atPath: path) {
                fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            fileHandle = FileHandle(forWritingAtPath: path)
            fileHandle?.seekToEndOfFile()
        }

        if let data = line.data(using: .utf8) {
            fileHandle?.write(data)
        }
    }

    private func cleanOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: logDir) else { return }
        let logFiles = files.filter { $0.hasPrefix("agent-events-") && $0.hasSuffix(".jsonl") }
            .sorted()
        // Keep last 7 days
        if logFiles.count > 7 {
            for file in logFiles.prefix(logFiles.count - 7) {
                try? fm.removeItem(atPath: (logDir as NSString).appendingPathComponent(file))
            }
        }
    }

    private static func dateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }
}
