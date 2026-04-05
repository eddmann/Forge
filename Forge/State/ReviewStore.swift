import Combine
import Foundation

final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()

    @Published private(set) var commentsByRoot: [String: [String: [AgentReviewComment]]] = [:]

    private var loadedRoots = Set<String>()
    private var saveCancellable: AnyCancellable?

    private init() {
        saveCancellable = $commentsByRoot
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] next in
                self?.persistAllRoots(next)
            }
    }

    func comments(in rootPath: String, filePath: String) -> [AgentReviewComment] {
        ensureLoaded(rootPath: rootPath)
        return (commentsByRoot[rootPath]?[filePath] ?? []).sorted(by: ReviewStore.commentSort)
    }

    func allComments(in rootPath: String) -> [AgentReviewComment] {
        ensureLoaded(rootPath: rootPath)
        return (commentsByRoot[rootPath] ?? [:])
            .values
            .flatMap { $0 }
            .sorted(by: ReviewStore.commentSort)
    }

    func comments(in rootPath: String, filePath: String, line: Int, side: AgentReviewCommentSide) -> [AgentReviewComment] {
        comments(in: rootPath, filePath: filePath).filter { comment in
            comment.side == side && (comment.startLine ... comment.endLine).contains(line)
        }
    }

    func addComment(
        rootPath: String,
        filePath: String,
        startLine: Int,
        endLine: Int? = nil,
        side: AgentReviewCommentSide,
        category: AgentReviewCommentCategory,
        text: String,
        codeSnippet: String
    ) {
        ensureLoaded(rootPath: rootPath)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let comment = AgentReviewComment(
            id: UUID().uuidString,
            filePath: filePath,
            startLine: startLine,
            endLine: endLine ?? startLine,
            side: side,
            category: category,
            codeSnippet: codeSnippet,
            text: trimmedText,
            createdAt: Date()
        )

        var next = commentsByRoot
        var repoComments = next[rootPath] ?? [:]
        var fileComments = repoComments[filePath] ?? []
        fileComments.append(comment)
        repoComments[filePath] = fileComments.sorted(by: ReviewStore.commentSort)
        next[rootPath] = repoComments
        commentsByRoot = next
    }

    func updateComment(
        rootPath: String,
        filePath: String,
        commentID: String,
        category: AgentReviewCommentCategory,
        text: String
    ) {
        ensureLoaded(rootPath: rootPath)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard var repoComments = commentsByRoot[rootPath],
              var fileComments = repoComments[filePath],
              let index = fileComments.firstIndex(where: { $0.id == commentID }) else { return }

        fileComments[index].category = category
        fileComments[index].text = trimmedText
        repoComments[filePath] = fileComments.sorted(by: ReviewStore.commentSort)

        var next = commentsByRoot
        next[rootPath] = repoComments
        commentsByRoot = next
    }

    func removeComment(rootPath: String, filePath: String, commentID: String) {
        ensureLoaded(rootPath: rootPath)
        guard var repoComments = commentsByRoot[rootPath],
              var fileComments = repoComments[filePath] else { return }

        fileComments.removeAll { $0.id == commentID }
        if fileComments.isEmpty {
            repoComments.removeValue(forKey: filePath)
        } else {
            repoComments[filePath] = fileComments
        }

        var next = commentsByRoot
        if repoComments.isEmpty {
            next.removeValue(forKey: rootPath)
        } else {
            next[rootPath] = repoComments
        }
        commentsByRoot = next
    }

    func clearComments(in rootPath: String) {
        ensureLoaded(rootPath: rootPath)
        guard commentsByRoot[rootPath] != nil else { return }
        var next = commentsByRoot
        next.removeValue(forKey: rootPath)
        commentsByRoot = next
        removeWorkingDocument(for: rootPath)
    }

    func exportMarkup(
        repoRoot: String,
        selectedRoot: String,
        baseRef: String? = nil,
        headRef: String? = nil
    ) -> String {
        let payload = AgentReviewPayloadBuilder.build(
            repoRoot: repoRoot,
            selectedRoot: selectedRoot,
            baseRef: baseRef,
            headRef: headRef,
            comments: allComments(in: selectedRoot)
        )
        return AgentReviewPayloadBuilder.exportMarkup(for: payload)
    }

    func exportMarkupDocument(
        repoRoot: String,
        selectedRoot: String,
        projectName: String,
        currentBranch: String?
    ) throws -> URL {
        let markup = exportMarkup(
            repoRoot: repoRoot,
            selectedRoot: selectedRoot,
            baseRef: nil,
            headRef: currentBranch?.isEmpty == false ? currentBranch : nil
        )

        let reviewsDir = reviewExportDirectory(for: selectedRoot)
        try FileManager.default.createDirectory(at: reviewsDir, withIntermediateDirectories: true)

        let slug = projectName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(slug.isEmpty ? "review" : slug)-\(timestamp).md"
        let outputURL = reviewsDir.appendingPathComponent(filename)
        try markup.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    private func ensureLoaded(rootPath: String) {
        guard !loadedRoots.contains(rootPath) else { return }
        loadedRoots.insert(rootPath)

        let url = workingReviewURL(for: rootPath)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        let parsed = parseMarkdown(contents)
        if !parsed.isEmpty {
            commentsByRoot[rootPath] = parsed
        }
    }

    private func persistAllRoots(_ snapshot: [String: [String: [AgentReviewComment]]]) {
        for (rootPath, comments) in snapshot {
            persist(rootPath: rootPath, comments: comments)
        }
    }

    private func persist(rootPath: String, comments: [String: [AgentReviewComment]]) {
        let url = workingReviewURL(for: rootPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let markdown = renderMarkdown(rootPath: rootPath, comments: comments)
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private func removeWorkingDocument(for rootPath: String) {
        let url = workingReviewURL(for: rootPath)
        try? FileManager.default.removeItem(at: url)
    }

    private func workingReviewURL(for rootPath: String) -> URL {
        workingReviewDirectory(for: rootPath).appendingPathComponent("working-comments.md")
    }

    /// Working comments stored in ~/.forge/reviews/<hash>/ to avoid polluting the repo.
    private func workingReviewDirectory(for rootPath: String) -> URL {
        let hash = rootPath.data(using: .utf8).map {
            $0.map { String(format: "%02x", $0) }.suffix(16).joined()
        } ?? "default"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("\(ForgeStore.forgeDirName)/reviews")
            .appendingPathComponent(hash)
    }

    /// Exports stored alongside working comments in ~/.forge/reviews/<hash>/
    private func reviewExportDirectory(for rootPath: String) -> URL {
        workingReviewDirectory(for: rootPath)
    }

    private func renderMarkdown(rootPath: String, comments: [String: [AgentReviewComment]]) -> String {
        var lines = [
            "# Forge Review Comments",
            "",
            "<!-- forge-review-root \(rootPath) -->"
        ]

        for filePath in comments.keys.sorted() {
            lines.append("")
            lines.append("## \(filePath)")
            for comment in (comments[filePath] ?? []).sorted(by: ReviewStore.commentSort) {
                lines.append("")
                lines.append("### Comment \(comment.id)")
                lines.append("<!-- forge-review-meta \(reviewMetaString(for: comment)) -->")
                lines.append(comment.text)
                if !comment.codeSnippet.isEmpty {
                    lines.append("")
                    lines.append("```diff")
                    lines.append(comment.codeSnippet)
                    lines.append("```")
                }
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func parseMarkdown(_ markdown: String) -> [String: [AgentReviewComment]] {
        let pattern = #"(?ms)^## (.+?)\n(.*?)(?=^## |\z)"#
        guard let fileRegex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        var result: [String: [AgentReviewComment]] = [:]

        for fileMatch in fileRegex.matches(in: markdown, range: nsRange) {
            guard
                let fileRange = Range(fileMatch.range(at: 1), in: markdown),
                let bodyRange = Range(fileMatch.range(at: 2), in: markdown)
            else {
                continue
            }
            let filePath = String(markdown[fileRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let block = String(markdown[bodyRange])
            let comments = parseCommentBlock(filePath: filePath, block: block)
            if !comments.isEmpty {
                result[filePath] = comments
            }
        }

        return result
    }

    private func parseCommentBlock(filePath: String, block: String) -> [AgentReviewComment] {
        let pattern = #"(?ms)^### Comment (.+?)\n<!-- forge-review-meta (\{.+?\}) -->\n(.*?)(?=^### Comment |\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(block.startIndex ..< block.endIndex, in: block)

        return regex.matches(in: block, range: nsRange).compactMap { match in
            guard
                let idRange = Range(match.range(at: 1), in: block),
                let metaRange = Range(match.range(at: 2), in: block),
                let contentRange = Range(match.range(at: 3), in: block)
            else {
                return nil
            }

            let id = String(block[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let metaString = String(block[metaRange])
            let content = String(block[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let components = splitReviewContent(content)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = metaString.data(using: .utf8),
                  let meta = try? decoder.decode(ReviewMarkdownMetadata.self, from: data)
            else {
                return nil
            }

            return AgentReviewComment(
                id: id,
                filePath: filePath,
                startLine: meta.startLine,
                endLine: meta.endLine,
                side: meta.side,
                category: meta.category,
                codeSnippet: components.codeSnippet,
                text: components.text,
                createdAt: meta.createdAt
            )
        }
    }

    private func splitReviewContent(_ content: String) -> (text: String, codeSnippet: String) {
        let fencedStart = "\n```diff\n"
        guard let range = content.range(of: fencedStart) else {
            return (content.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        let text = content[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let snippetStart = range.upperBound
        let snippetEnd = content.range(of: "\n```", range: snippetStart ..< content.endIndex)?.lowerBound ?? content.endIndex
        let snippet = content[snippetStart ..< snippetEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(text), String(snippet))
    }

    private func reviewMetaString(for comment: AgentReviewComment) -> String {
        let meta = ReviewMarkdownMetadata(
            startLine: comment.startLine,
            endLine: comment.endLine,
            side: comment.side,
            category: comment.category,
            createdAt: comment.createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(meta)) ?? Data("{}".utf8)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    private static func commentSort(_ lhs: AgentReviewComment, _ rhs: AgentReviewComment) -> Bool {
        if lhs.filePath != rhs.filePath {
            return lhs.filePath < rhs.filePath
        }
        if lhs.startLine != rhs.startLine {
            return lhs.startLine < rhs.startLine
        }
        if lhs.endLine != rhs.endLine {
            return lhs.endLine < rhs.endLine
        }
        return lhs.createdAt < rhs.createdAt
    }
}

private struct ReviewMarkdownMetadata: Codable {
    var startLine: Int
    var endLine: Int
    var side: AgentReviewCommentSide
    var category: AgentReviewCommentCategory
    var createdAt: Date
}
