import Foundation

/// Spawns a configurable CLI command to produce a one-line activity summary.
/// The system prompt + terminal context is piped via stdin.
enum SummaryCommand {
    static let defaultCommand = "claude -p --model haiku"

    private static let systemPrompt = """
    You are an activity summarizer for a developer workspace manager.
    Read the recent terminal activity and produce a single brief summary.
    - Tabs labelled CURRENT are the most recent work — prioritize summarizing what happened there.
    - Tabs labelled BACKGROUND provide supporting context for the broader workspace. \
    Mention them only if they add important context to the current work.
    - Be concise. The summary displays as a single line in a sidebar (~60-80 chars).
    - Front-load with the task and key subject (file, feature, error).
    - Respond with ONLY the summary line. No extra text.
    """

    /// Run the configured summarizer command with the given context piped via stdin.
    /// Returns a sanitized summary, or nil on failure.
    static func run(context: String, timeout: TimeInterval = 15) async -> String? {
        let command = ForgeStore.shared.loadStateFields().summarizerCommand
        let parts = parseCommandParts(command.isEmpty ? Self.defaultCommand : command)
        guard let binary = parts.first, !binary.isEmpty else {
            SummaryLog.log("[SummaryCommand] empty command configured")
            return nil
        }

        guard binaryAvailable(binary) else {
            SummaryLog.log("[SummaryCommand] '\(binary)' not available on PATH")
            return nil
        }
        SummaryLog.log("[SummaryCommand] running: \(command)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = parts
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ShellEnvironment.resolvedPath
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let input = "\(systemPrompt)\n\n---\n\n\(context)"

        do {
            try process.run()
        } catch {
            SummaryLog.log("[SummaryCommand] failed to launch: \(error)")
            return nil
        }

        // Write prompt + context to stdin and close
        stdinPipe.fileHandleForWriting.write(Data(input.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        // Enforce timeout
        let timeoutItem = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            SummaryLog.log("[SummaryCommand] exited with status \(process.terminationStatus), stderr: \(stderr.prefix(500))")
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else {
            SummaryLog.log("[SummaryCommand] failed to decode stdout as UTF-8")
            return nil
        }

        let result = sanitize(raw)
        SummaryLog.log("[SummaryCommand] raw='\(raw.prefix(200))' sanitized='\(result ?? "nil")'")
        return result
    }

    // MARK: - Shared Helpers

    /// Split a command string into arguments, respecting single/double quotes.
    static func parseCommandParts(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false

        for char in command {
            if char == "'", !inDoubleQuote {
                inSingleQuote.toggle()
            } else if char == "\"", !inSingleQuote {
                inDoubleQuote.toggle()
            } else if char == " ", !inSingleQuote, !inDoubleQuote {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { args.append(current) }
        return args
    }

    static func binaryAvailable(_ binary: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]
        process.environment = ["PATH": ShellEnvironment.resolvedPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common markdown/prefix patterns
        let prefixes = ["**Summary:**", "**Summary**:", "Summary:", "summary:"]
        for prefix in prefixes {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip surrounding quotes
        if text.count >= 2,
           (text.hasPrefix("\"") && text.hasSuffix("\"")) ||
           (text.hasPrefix("'") && text.hasSuffix("'"))
        {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Take only the first line
        if let firstLine = text.components(separatedBy: .newlines).first {
            text = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }

        // Truncate to 100 chars
        if text.count > 100 {
            text = String(text.prefix(97)) + "..."
        }

        return text
    }
}
