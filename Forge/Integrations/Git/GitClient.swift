import Foundation

struct GitCommandResult {
    let success: Bool
    let stdout: String
    let stderr: String

    var output: String {
        success ? stdout : stderr
    }

    var trimmedOutput: String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol GitClient {
    func run(in directory: String, args: [String]) -> GitCommandResult
    func runAsync(in directory: String, args: [String], completion: @escaping (GitCommandResult) -> Void)
    func runWithStdin(in directory: String, args: [String], stdin: String) -> GitCommandResult
}

extension GitClient {
    func runOrThrow(in directory: String, args: [String]) throws -> GitCommandResult {
        let result = run(in: directory, args: args)
        guard result.success else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: result.trimmedOutput]
            )
        }
        return result
    }

    func currentBranch(in directory: String) -> String? {
        let result = run(in: directory, args: ["rev-parse", "--abbrev-ref", "HEAD"])
        guard result.success else { return nil }
        let branch = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }
}

enum Git {
    static var shared: any GitClient = ProcessGitClient.shared
}
