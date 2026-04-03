#if DEBUG
    import Foundation

    /// Demo modes for screenshots and testing.
    /// Launch with `--demo <mode>` to activate.
    enum DemoMode: String, CaseIterable {
        case projectList
        case splitDiff
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
            case .splitDiff: "Side-by-side diff view with file changes"
            case .diffReview: "Inspector with pending changes and commit composer"
            case .splitPanes: "Multiple split panes with agent activity"
            }
        }
    }
#endif
