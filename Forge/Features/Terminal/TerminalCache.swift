import AppKit
import Combine

class TerminalCache {
    static let shared = TerminalCache()

    private var cache: [UUID: GhosttyTerminalView] = [:]
    private var appearanceCancellable: AnyCancellable?

    private init() {
        // Subscribe to appearance changes and reload Ghostty config
        appearanceCancellable = TerminalAppearanceStore.shared.$config
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                GhosttyApp.shared.reloadAppearance()
            }
    }

    func terminalView(for session: TerminalSession) -> GhosttyTerminalView {
        if let existing = cache[session.id] {
            return existing
        }

        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.sessionID = session.id

        // When the process exits (shell exits), close the tab.
        view.onProcessExit = { id in
            DispatchQueue.main.async {
                TerminalSessionManager.shared.closeSession(id: id)
            }
        }

        // Check for restored scrollback from previous session
        var additionalEnv: [String: String] = [:]
        let sessionKey = session.id.uuidString
        MainActor.assumeIsolated {
            if ForgeStore.shared.loadStateFields().restoreScrollback,
               let scrollbackText = TerminalSessionManager.shared.restoredScrollback.removeValue(forKey: sessionKey)
            {
                if let filePath = Self.writeScrollbackTempFile(sessionID: session.id, text: scrollbackText) {
                    additionalEnv["FORGE_RESTORE_SCROLLBACK_FILE"] = filePath
                }
            } else {
                TerminalSessionManager.shared.restoredScrollback.removeValue(forKey: sessionKey)
            }

            // Ensure welcome function exists for this workspace, then pass path
            if let tab = TerminalSessionManager.shared.tabs.first(where: {
                $0.sessionIDs.contains(session.id) || $0.paneManager?.allSessionIDs.contains(session.id) == true
            }),
                let wsID = tab.workspaceID
            {
                TerminalSessionManager.shared.ensureWelcomeFunction(workspaceID: wsID)
                if let fnPath = TerminalSessionManager.shared.welcomeFunctionPaths[wsID] {
                    additionalEnv["FORGE_WELCOME_FN_PATH"] = fnPath
                }
            }

            // Auto-run welcome on new workspace sessions
            if TerminalSessionManager.shared.pendingShowWelcome.remove(session.id) != nil {
                additionalEnv["FORGE_SHOW_WELCOME"] = "1"
            }
        }

        view.startShell(in: session.workingDirectory, sessionID: session.id, additionalEnv: additionalEnv)

        cache[session.id] = view

        // Send launch command after shell starts.
        let isRestored = MainActor.assumeIsolated {
            TerminalSessionManager.shared.restoredSessionIDs.remove(session.id) != nil
        }

        if let command = session.launchCommand {
            if isRestored {
                // Restored session: inject command into prompt without executing.
                // If the agent reported a session ID, append --resume so the user
                // can pick up where they left off by pressing Enter.
                let prefill = if let agentSID = session.agentSessionID {
                    Self.resumeCommand(base: command, agentSessionID: agentSID)
                } else {
                    command
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    view.sendInput(prefill)
                }
            } else {
                // New session: execute immediately
                let input = session.closeOnExit ? "\(command); exit\r" : "\(command)\r"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    view.sendInput(input)
                }
            }
        } else if isRestored {
            // Plain shell restored: inject last command from per-session history
            if let lastCmd = Self.lastHistoryCommand(sessionID: session.id) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    view.sendInput(lastCmd)
                }
            }
        }

        return view
    }

    func remove(_ id: UUID) {
        if let view = cache[id] {
            view.terminate()
            view.removeFromSuperview()
            cache.removeValue(forKey: id)
        }
    }

    func view(for id: UUID) -> GhosttyTerminalView? {
        cache[id]
    }

    // MARK: - Agent Resume

    /// Appends the agent-specific resume flag to a launch command.
    /// Returns the original command unchanged for unknown agents.
    private static func resumeCommand(base: String, agentSessionID: String) -> String {
        let tokens = base.split(separator: " ", omittingEmptySubsequences: true)
        let commandName = tokens.first(where: { !$0.contains("=") }).map(String.init) ?? ""

        switch commandName {
        case "claude": return "\(base) --resume \(agentSessionID)"
        case "codex": return "\(base) --resume \(agentSessionID)"
        default: return base
        }
    }

    // MARK: - Per-Session History

    private static func lastHistoryCommand(sessionID: UUID) -> String? {
        let path = NSHomeDirectory() + "/.forge/state/history/\(sessionID.uuidString)"
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return nil }

        // zsh extended history format: ": timestamp:0;command" — extract the command part
        // bash format: plain command per line
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let lastLine = lines.last else { return nil }

        // Handle zsh extended history format
        if lastLine.hasPrefix(": "), lastLine.contains(";") {
            if let semicolonIndex = lastLine.firstIndex(of: ";") {
                let cmd = String(lastLine[lastLine.index(after: semicolonIndex)...])
                return cmd.isEmpty ? nil : cmd
            }
        }

        return lastLine
    }

    // MARK: - Scrollback Persistence

    private static func writeScrollbackTempFile(sessionID: UUID, text: String) -> String? {
        let dir = NSHomeDirectory() + "/.forge/state/scrollback"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(sessionID.uuidString).txt")
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }
}
