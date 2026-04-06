import Foundation

/// Spawns the configured summarizer CLI to produce a narrative snapshot
/// of a single terminal tab's recent activity.
enum ActivitySnapshotCommand {
    static let unchangedSentinel = "UNCHANGED"

    private static let basePrompt = """
    You are a workspace narrator for a developer tool.
    Read the recent terminal activity and describe what the agent is currently working on in 1-2 sentences.
    - Be specific: mention file names, features, or errors when relevant.
    - Write in present tense ("Adding OAuth2 support", "Fixing compilation error in auth module").
    - Respond with ONLY the narrative. No extra text.
    """

    private static let diffSuffix = """

    The previous update said: "%@"
    Only produce a new summary if the work has meaningfully progressed or changed direction.
    If nothing meaningful has changed, respond with exactly: UNCHANGED
    """

    /// Run the summarizer with single-tab context, returning a narrative snapshot.
    /// Returns `nil` on failure. Returns `"UNCHANGED"` if the AI determines nothing new happened.
    static func run(context: String, previousSummary: String? = nil, timeout: TimeInterval = 15) async -> String? {
        var prompt = basePrompt
        if let previousSummary, !previousSummary.isEmpty {
            prompt += String(format: diffSuffix, previousSummary)
        }

        let command = ForgeStore.shared.loadStateFields().summarizerCommand
        let parts = SummaryCommand.parseCommandParts(command.isEmpty ? SummaryCommand.defaultCommand : command)
        guard let binary = parts.first, !binary.isEmpty else { return nil }

        guard SummaryCommand.binaryAvailable(binary) else { return nil }

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

        let input = "\(prompt)\n\n---\n\n\(context)"

        do {
            try process.run()
        } catch {
            return nil
        }

        stdinPipe.fileHandleForWriting.write(Data(input.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        let timeoutItem = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()

        guard process.terminationStatus == 0 else { return nil }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8) else { return nil }

        return sanitize(raw)
    }

    private static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip surrounding quotes
        if text.count >= 2,
           (text.hasPrefix("\"") && text.hasSuffix("\"")) ||
           (text.hasPrefix("'") && text.hasSuffix("'"))
        {
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }

        return text
    }
}
