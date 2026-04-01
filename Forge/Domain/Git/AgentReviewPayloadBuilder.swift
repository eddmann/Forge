import Foundation

struct AgentReviewPayload: Codable {
    var repoRoot: String
    var selectedRoot: String
    var baseRef: String?
    var headRef: String?
    var summary: AgentReviewSummary
    var comments: [AgentReviewComment]
}

struct AgentReviewSummary: Codable, Hashable {
    var totalComments: Int
    var actionRequired: Int
    var issues: Int
    var suggestions: Int
    var questions: Int
    var nitpicks: Int
    var praise: Int
}

struct AgentReviewComment: Codable, Hashable, Identifiable {
    var id: String
    var filePath: String
    var startLine: Int
    var endLine: Int
    var side: AgentReviewCommentSide
    var category: AgentReviewCommentCategory
    var codeSnippet: String
    var text: String
    var createdAt: Date
}

enum AgentReviewCommentSide: String, Codable, Hashable {
    case old
    case new
}

enum AgentReviewCommentCategory: String, Codable, CaseIterable, Hashable {
    case suggestion
    case issue
    case question
    case nitpick
    case praise

    var requiresAction: Bool {
        switch self {
        case .issue, .suggestion:
            true
        case .question, .nitpick, .praise:
            false
        }
    }
}

enum AgentReviewPayloadBuilder {
    static func build(
        repoRoot: String,
        selectedRoot: String,
        baseRef: String?,
        headRef: String?,
        comments: [AgentReviewComment]
    ) -> AgentReviewPayload {
        let sortedComments = comments.sorted {
            if $0.filePath != $1.filePath {
                return $0.filePath < $1.filePath
            }
            if $0.startLine != $1.startLine {
                return $0.startLine < $1.startLine
            }
            return $0.createdAt < $1.createdAt
        }

        return AgentReviewPayload(
            repoRoot: repoRoot,
            selectedRoot: selectedRoot,
            baseRef: baseRef,
            headRef: headRef,
            summary: makeSummary(for: sortedComments),
            comments: sortedComments
        )
    }

    static func exportMarkup(for payload: AgentReviewPayload) -> String {
        guard !payload.comments.isEmpty else { return "" }

        let summary = payload.summary
        let lineSummary = "Total: \(summary.totalComments) comment\(suffix(for: summary.totalComments))"
        let actionSummary = "Action required: \(summary.actionRequired)" +
            (summary.actionRequired > 0
                ? " (\(summary.issues) issue\(suffix(for: summary.issues)), \(summary.suggestions) suggestion\(suffix(for: summary.suggestions)))"
                : "")
        let questionSummary = "Questions: \(summary.questions)"

        var output = """
        <forge-review>
        The user has reviewed code changes and left \(summary.totalComments) comment\(suffix(for: summary.totalComments)). Process each comment according to its category.

        <review-categories>
        - ISSUE: Bug or error - must be fixed
        - SUGGESTION: Improvement - implement unless problematic
        - QUESTION: Clarification needed - explain your reasoning
        - NITPICK: Minor preference - fix if easy
        - PRAISE: Positive feedback - no change needed
        </review-categories>

        <review-summary>
        \(lineSummary)
        \(actionSummary)
        \(questionSummary)
        </review-summary>

        """

        for (index, comment) in payload.comments.enumerated() {
            let lineRef = comment.startLine == comment.endLine
                ? "\(comment.startLine)"
                : "\(comment.startLine)-\(comment.endLine)"
            let codeBlock: String
            if comment.codeSnippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                codeBlock = ""
            } else {
                let language = languageForFile(at: comment.filePath)
                codeBlock = """
                <code language="\(xmlEscaped(language))">
                \(xmlEscaped(comment.codeSnippet))</code>

                """
            }

            output += """
            <comment id="\(index + 1)">
            <file>\(xmlEscaped(comment.filePath))</file>
            <line>\(lineRef)</line>
            <side>\(comment.side.rawValue)</side>
            <category>\(comment.category.rawValue)</category>
            \(codeBlock)<text>\(xmlEscaped(comment.text))</text>
            </comment>

            """
        }

        output += "</forge-review>"
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeSummary(for comments: [AgentReviewComment]) -> AgentReviewSummary {
        var counts: [AgentReviewCommentCategory: Int] = [:]
        for category in AgentReviewCommentCategory.allCases {
            counts[category] = 0
        }

        for comment in comments {
            counts[comment.category, default: 0] += 1
        }

        return AgentReviewSummary(
            totalComments: comments.count,
            actionRequired: comments.filter(\.category.requiresAction).count,
            issues: counts[.issue, default: 0],
            suggestions: counts[.suggestion, default: 0],
            questions: counts[.question, default: 0],
            nitpicks: counts[.nitpick, default: 0],
            praise: counts[.praise, default: 0]
        )
    }

    private static func suffix(for count: Int) -> String {
        count == 1 ? "" : "s"
    }

    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func languageForFile(at path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift":
            "swift"
        case "ts":
            "typescript"
        case "tsx":
            "tsx"
        case "js":
            "javascript"
        case "jsx":
            "jsx"
        case "rb":
            "ruby"
        case "py":
            "python"
        case "rs":
            "rust"
        case "go":
            "go"
        case "java":
            "java"
        case "kt":
            "kotlin"
        case "m":
            "objective-c"
        case "mm":
            "objective-cpp"
        case "c":
            "c"
        case "cc", "cpp", "cxx":
            "cpp"
        case "json":
            "json"
        case "md":
            "markdown"
        case "yml", "yaml":
            "yaml"
        case "xml":
            "xml"
        case "html":
            "html"
        case "css":
            "css"
        case "scss":
            "scss"
        case "sh":
            "bash"
        default:
            "text"
        }
    }
}
