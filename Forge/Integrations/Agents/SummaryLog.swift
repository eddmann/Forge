import Foundation

/// Simple file logger for debugging the summarization pipeline.
/// Writes to ~/.forge/state/summary.log
enum SummaryLog {
    private static let logPath: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("\(ForgeStore.forgeDirName)/state")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("summary.log")
    }()

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
