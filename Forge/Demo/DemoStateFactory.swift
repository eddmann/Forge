#if DEBUG
    import Foundation

    /// Configures app stores with demo data for screenshots.
    @MainActor
    enum DemoStateFactory {
        /// Populates stores for the given demo mode.
        /// Returns true if the demo mode was configured (caller should skip normal persistence loading).
        static func configure(for mode: DemoMode) {
            configureProjects()
            configureSummaries()

            switch mode {
            case .projectList:
                configureProjectListMode()
            case .agentActive:
                configureAgentActiveMode()
            case .diffReview:
                configureDiffReviewMode()
            case .splitPanes:
                configureSplitPanesMode()
            }
        }

        // MARK: - Shared Setup

        private static func configureProjects() {
            let store = ProjectStore.shared
            store.projects = DemoData.projects()
            store.workspaces = DemoData.workspaces()
        }

        private static func configureSummaries() {
            for (id, summary) in DemoData.summaries() {
                SummaryStore.shared.setDemo(workspaceID: id, summary: summary)
            }
        }

        // MARK: - Mode-Specific Configuration

        private static func configureProjectListMode() {
            let store = ProjectStore.shared
            store.activeProjectID = DemoData.projectIDs.api
            store.activeWorkspaceID = DemoData.workspaceIDs.charmander
            store.currentBranch = "forge/charmander"

            // Agent thinking on growlithe workspace
            let tabID = DemoData.tabIDs.tab1
            AgentEventStore.shared.activityByTab[tabID] = .toolExecuting
            AgentEventStore.shared.setDemoState(tabID: tabID, state: AgentSessionState(
                agent: "claude",
                activity: .toolExecuting,
                currentTool: ToolExecution(name: "Edit", input: ["file": "src/handlers/auth.ts"], startedAt: Date()),
                model: "claude-sonnet-4-20250514"
            ))

            // Set up demo file statuses
            let statuses = DemoData.fileStatuses()
            StatusViewModel.shared.setDemo(statuses: statuses)
        }

        private static func configureAgentActiveMode() {
            let store = ProjectStore.shared
            store.activeProjectID = DemoData.projectIDs.api
            store.activeWorkspaceID = DemoData.workspaceIDs.charmander
            store.currentBranch = "forge/charmander"

            let tabID = DemoData.tabIDs.tab1
            AgentEventStore.shared.activityByTab[tabID] = .toolExecuting
            AgentEventStore.shared.setDemoState(tabID: tabID, state: AgentSessionState(
                agent: "claude",
                activity: .toolExecuting,
                currentTool: ToolExecution(name: "Edit", input: ["file": "src/handlers/auth.ts"], startedAt: Date()),
                model: "claude-sonnet-4-20250514"
            ))

            let statuses = DemoData.fileStatuses()
            StatusViewModel.shared.setDemo(statuses: statuses)
        }

        private static func configureDiffReviewMode() {
            let store = ProjectStore.shared
            store.activeProjectID = DemoData.projectIDs.api
            store.activeWorkspaceID = DemoData.workspaceIDs.charmander
            store.currentBranch = "forge/charmander"

            let statuses = DemoData.fileStatuses()
            StatusViewModel.shared.setDemo(statuses: statuses, selectedPath: "src/handlers/auth.ts")

            // Agent idle — review in progress
            let tabID = DemoData.tabIDs.tab1
            AgentEventStore.shared.activityByTab[tabID] = .idle
        }

        private static func configureSplitPanesMode() {
            let store = ProjectStore.shared
            store.activeProjectID = DemoData.projectIDs.api
            store.activeWorkspaceID = DemoData.workspaceIDs.charmander
            store.currentBranch = "forge/charmander"

            // Multiple agents active
            AgentEventStore.shared.activityByTab[DemoData.tabIDs.tab1] = .toolExecuting
            AgentEventStore.shared.setDemoState(tabID: DemoData.tabIDs.tab1, state: AgentSessionState(
                agent: "claude",
                activity: .toolExecuting,
                currentTool: ToolExecution(name: "Bash", input: ["command": "npm test"], startedAt: Date()),
                model: "claude-sonnet-4-20250514"
            ))

            AgentEventStore.shared.activityByTab[DemoData.tabIDs.tab2] = .thinking
            AgentEventStore.shared.setDemoState(tabID: DemoData.tabIDs.tab2, state: AgentSessionState(
                agent: "claude",
                activity: .thinking,
                model: "claude-sonnet-4-20250514"
            ))

            // Unread notification on tab2
            AgentEventStore.shared.setDemoUnread(tabID: DemoData.tabIDs.tab2, count: 1)

            let statuses = DemoData.fileStatuses()
            StatusViewModel.shared.setDemo(statuses: statuses)
        }
    }
#endif
