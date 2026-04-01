import Foundation

/// Schedules workspace activity summarization when agents finish work.
/// Debounces requests and collects terminal scrollback from all tabs in the workspace.
@MainActor
class SummaryScheduler {
    static let shared = SummaryScheduler()

    private var debounceTimers: [UUID: DispatchWorkItem] = [:]
    private let debounceInterval: TimeInterval = 3.0

    private init() {}

    /// Called when an agent transitions to idle in a workspace.
    /// Debounces and triggers summarization after a short delay.
    func workspaceActivityDetected(workspaceID: UUID) {
        guard ForgeStore.shared.loadStateFields().workspaceSummariesEnabled else { return }

        // Cancel any pending debounce for this workspace
        debounceTimers[workspaceID]?.cancel()

        let item = DispatchWorkItem { [weak self] in
            self?.triggerSummarization(workspaceID: workspaceID)
        }
        debounceTimers[workspaceID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    // MARK: - Private

    private func triggerSummarization(workspaceID: UUID) {
        debounceTimers.removeValue(forKey: workspaceID)

        let store = SummaryStore.shared
        guard !store.isInFlight(workspaceID) else {
            SummaryLog.log("[Summary] Skipped: already in-flight for workspace \(workspaceID)")
            return
        }

        let context = collectContext(workspaceID: workspaceID)
        guard !context.isEmpty else {
            SummaryLog.log("[Summary] Skipped: no scrollback context for workspace \(workspaceID)")
            return
        }
        SummaryLog.log("[Summary] Collected \(context.count) chars of context, spawning claude...")

        store.markInFlight(workspaceID)

        Task.detached(priority: .utility) {
            let summary = await SummaryCommand.run(context: context)

            await MainActor.run {
                if let summary {
                    SummaryLog.log("[Summary] Storing summary for workspace \(workspaceID): '\(summary)'")
                    store.updateSummary(workspaceID: workspaceID, summary: summary)
                    SummaryLog.log("[Summary] Store now has: \(store.summaryByWorkspace)")
                } else {
                    SummaryLog.log("[Summary] No summary returned, clearing in-flight")
                    store.clearInFlight(workspaceID)
                }
            }
        }
    }

    private func collectContext(workspaceID: UUID) -> String {
        let tabs = TerminalSessionManager.shared.tabs.filter {
            $0.workspaceID == workspaceID && $0.kind.isTerminal
        }

        var parts: [String] = []
        var totalLength = 0
        let maxLength = 4000

        for tab in tabs {
            let sessionIDs = tab.paneManager?.allSessionIDs ?? tab.sessionIDs
            for sessionID in sessionIDs {
                guard totalLength < maxLength else { break }

                guard let view = TerminalCache.shared.view(for: sessionID),
                      let scrollback = view.captureScrollback(lineLimit: 200) else { continue }

                // Strip ANSI escape sequences for cleaner LLM input
                let cleaned = Self.stripANSI(scrollback)
                guard !cleaned.isEmpty else { continue }

                let label = "[\(tab.title)]"
                let chunk = "\(label)\n\(cleaned)"

                let remaining = maxLength - totalLength
                if chunk.count > remaining {
                    parts.append(String(chunk.prefix(remaining)))
                    totalLength = maxLength
                } else {
                    parts.append(chunk)
                    totalLength += chunk.count
                }
            }
        }

        return parts.joined(separator: "\n\n")
    }

    private static func stripANSI(_ text: String) -> String {
        // Remove ANSI escape sequences: ESC[ ... m and other CSI sequences
        guard let regex = try? NSRegularExpression(pattern: "\\x1b\\[[0-9;]*[a-zA-Z]") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
