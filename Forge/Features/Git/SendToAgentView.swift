import SwiftUI

/// Popover shown when "Send to Agent" is clicked. Writes review to .forge/reviews/
/// and either injects @file reference into a running agent or launches a new one.
struct SendToAgentView: View {
    let markup: String
    let repoPath: String
    let onDismiss: () -> Void

    @State private var agentSessions: [AgentSessionInfo] = []
    @State private var isScanning = true
    @State private var reviewFilePath: String?
    @State private var writeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                Text("Send Review to Agent")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            if let error = writeError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else if isScanning {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning sessions...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                // Review file info
                if let path = reviewFilePath {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.03))
                }

                // Running agent sessions
                if !agentSessions.isEmpty {
                    sectionHeader("Running Agents")

                    ForEach(agentSessions) { session in
                        AgentSessionRow(session: session) {
                            sendToSession(session)
                        }
                    }
                } else {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Image(systemName: "cpu")
                                .font(.system(size: 16))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            Text("No agents running")
                                .font(.system(size: 12))
                                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }

                Divider().opacity(0.3)

                // Launch new agent with review
                sectionHeader("Launch with Review")

                ForEach(AgentStore.shared.agents) { agent in
                    LaunchAgentRow(agent: agent) {
                        launchAgentWithReview(agent)
                    }
                }
            }

            Divider().opacity(0.3)

            // Copy to clipboard fallback
            Button(action: { copyToClipboard() }) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                    Text("Copy to Clipboard")
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 300)
        .background(Color(nsColor: NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            writeReviewFile()
            scanForAgents()
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Write Review File

    private func writeReviewFile() {
        guard !markup.isEmpty else {
            writeError = "No review comments to send."
            return
        }

        let reviewsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".forge/reviews")

        do {
            try FileManager.default.createDirectory(at: reviewsDir, withIntermediateDirectories: true)

            let projectName = (repoPath as NSString).lastPathComponent
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let shortID = UUID().uuidString.prefix(8).lowercased()
            let filename = "\(projectName.isEmpty ? "review" : projectName)-\(shortID).xml"
            let fileURL = reviewsDir.appendingPathComponent(filename)

            try markup.write(to: fileURL, atomically: true, encoding: .utf8)
            reviewFilePath = fileURL.path
        } catch {
            writeError = "Failed to write review: \(error.localizedDescription)"
        }
    }

    // MARK: - Scanning

    private func scanForAgents() {
        let manager = TerminalSessionManager.shared
        let activeProject = manager.activeProjectID
        let activeWorkspace = manager.activeWorkspaceID
        var found: [AgentSessionInfo] = []

        for tab in manager.tabs {
            guard tab.projectID == activeProject, tab.workspaceID == activeWorkspace else { continue }
            let sessionIDs = tab.paneManager?.allSessionIDs ?? tab.sessionIDs

            for sessionID in sessionIDs {
                if let agentCommand = AgentDetector.shared.detectAgent(sessionID: sessionID) {
                    found.append(AgentSessionInfo(
                        sessionID: sessionID,
                        agentCommand: agentCommand,
                        tabTitle: tab.title
                    ))
                }
            }
        }

        agentSessions = found
        isScanning = false
    }

    // MARK: - Actions

    /// Send @file reference to a running agent session
    private func sendToSession(_ session: AgentSessionInfo) {
        guard let path = reviewFilePath,
              let terminalView = TerminalCache.shared.view(for: session.sessionID) else { return }

        let relativePath = path.hasPrefix(repoPath)
            ? String(path.dropFirst(repoPath.count + 1))
            : path

        terminalView.sendInput("@\(relativePath)")

        // Switch to the agent's tab
        TerminalSessionManager.shared.activateSession(id: session.sessionID)

        // Clear review comments — they're now persisted in the XML file
        clearReviewComments()
        recordActivity()
        onDismiss()
    }

    /// Launch a new agent tab with the review file
    private func launchAgentWithReview(_ agent: AgentConfig) {
        guard let path = reviewFilePath else { return }

        let relativePath = path.hasPrefix(repoPath)
            ? String(path.dropFirst(repoPath.count + 1))
            : path

        let launchCmd = agent.reviewLaunchCommand(reviewFilePath: relativePath)

        TerminalSessionManager.shared.createSession(
            workingDirectory: repoPath,
            title: agent.name,
            launchCommand: launchCmd,
            projectID: TerminalSessionManager.shared.activeProjectID,
            workspaceID: TerminalSessionManager.shared.activeWorkspaceID,
            icon: agent.icon
        )

        // Clear review comments — they're now persisted in the XML file
        clearReviewComments()
        recordActivity()
        onDismiss()
    }

    private func clearReviewComments() {
        ReviewStore.shared.clearComments(in: repoPath)
        StatusViewModel.shared.refresh()
    }

    private func recordActivity() {
        if let pid = TerminalSessionManager.shared.activeProjectID {
            ProjectStore.shared.recordActivity(for: pid)
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markup, forType: .string)
        onDismiss()
    }
}

// MARK: - Agent Session Info

struct AgentSessionInfo: Identifiable {
    let sessionID: UUID
    let agentCommand: String
    let tabTitle: String
    var id: UUID {
        sessionID
    }
}

// MARK: - Agent Session Row

private struct AgentSessionRow: View {
    let session: AgentSessionInfo
    let onSend: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSend) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.agentCommand)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(session.tabTitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isHovered ? Color.white.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Launch Agent Row

private struct LaunchAgentRow: View {
    let agent: AgentConfig
    let onLaunch: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onLaunch) {
            HStack(spacing: 8) {
                AgentIconView(agent: agent)
                    .font(.system(size: 11))
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    if let rc = agent.reviewCommand, !rc.isEmpty {
                        Text(rc)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(isHovered ? Color.white.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
