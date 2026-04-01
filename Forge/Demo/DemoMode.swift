#if DEBUG
    import Foundation

    /// Demo modes for screenshots and testing.
    /// Launch with `--demo <mode>` to activate.
    enum DemoMode: String, CaseIterable {
        case projectList
        case agentActive
        case diffReview
        case splitPanes

        static func fromArguments() -> DemoMode? {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "--demo"),
                  index + 1 < args.count
            else {
                return nil
            }
            return DemoMode(rawValue: args[index + 1])
        }

        var description: String {
            switch self {
            case .projectList: "Sidebar with projects and workspaces"
            case .agentActive: "Agent mid-task with file changes"
            case .diffReview: "Inspector showing unified diff review"
            case .splitPanes: "Multiple split panes with agent activity"
            }
        }
    }
#endif
