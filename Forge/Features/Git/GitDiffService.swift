import Foundation

final class GitDiffService {
    static let shared = GitDiffService()

    private let client: any GitClient
    private let parser: GitUnifiedDiffParser

    init(client: any GitClient = Git.shared, parser: GitUnifiedDiffParser = GitUnifiedDiffParser()) {
        self.client = client
        self.parser = parser
    }

    func diff(in repoPath: String, request: GitDiffRequest) throws -> GitDiffResult {
        let result = client.run(in: repoPath, args: makeArgs(for: request))
        guard result.success else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: result.trimmedOutput]
            )
        }
        return parser.parse(result.stdout)
    }

    func diffAsync(in repoPath: String, request: GitDiffRequest, completion: @escaping (Result<GitDiffResult, Error>) -> Void) {
        client.runAsync(in: repoPath, args: makeArgs(for: request)) { [parser] result in
            if result.success {
                completion(.success(parser.parse(result.stdout)))
            } else {
                completion(.failure(NSError(
                    domain: NSPOSIXErrorDomain,
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: result.trimmedOutput]
                )))
            }
        }
    }

    private func makeArgs(for request: GitDiffRequest) -> [String] {
        var args = [
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--find-renames",
            "--submodule=diff",
            "--unified=\(request.contextLines)"
        ]

        switch (request.base, request.head) {
        case (.index, .workingTree):
            break
        case let (.revision(base), .index):
            args.append("--cached")
            args.append(base)
        case let (.revision(base), .workingTree):
            args.append(base)
        case let (.revision(base), .revision(head)):
            args.append(base)
            args.append(head)
        default:
            // Unsupported combinations can be added when the UI needs them.
            break
        }

        if !request.paths.isEmpty {
            args.append("--")
            args.append(contentsOf: request.paths)
        }

        return args
    }
}
