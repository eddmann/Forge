import Darwin
import Foundation

enum WorkspaceCloner {
    struct CloneResult {
        var fullClone: Bool
    }

    // MARK: - Create Workspace

    static func createWorkspace(
        projectID: UUID,
        projectName: String,
        projectPath: String,
        parentBranch: String
    ) throws -> Workspace {
        let existingNames = ProjectStore.shared.workspaces.map(\.name)
        let name = WorkspaceNaming.generateUnique(existing: existingNames)

        let destDirName = "\(projectName)-\(name)"
        let destPath = ForgeStore.shared.clonesDir.appendingPathComponent(destDirName).path

        let result = try cloneProject(source: projectPath, dest: destPath)

        // Make the selected branch the base for the workspace branch.
        try checkoutWorkspaceBaseBranch(in: destPath, parentBranch: parentBranch)

        // Create and checkout workspace branch
        let branchName = "forge/\(name)"
        let (branchExists, _) = runGitSync(in: destPath, args: ["rev-parse", "--verify", "refs/heads/\(branchName)"])
        if !branchExists {
            try runGitOrThrow(in: destPath, args: ["checkout", "-b", branchName])
        } else {
            try runGitOrThrow(in: destPath, args: ["checkout", branchName])
        }

        // Fix remote origin to point to original's upstream, not local path
        fixRemoteOrigin(source: projectPath, dest: destPath)

        return Workspace(
            projectID: projectID,
            name: name,
            path: destPath,
            branch: branchName,
            parentBranch: parentBranch,
            fullClone: result.fullClone
        )
    }

    private static func checkoutWorkspaceBaseBranch(in repositoryPath: String, parentBranch: String) throws {
        let currentBranch = Git.shared.currentBranch(in: repositoryPath)
        if currentBranch == parentBranch {
            return
        }

        let (hasLocalBranch, _) = runGitSync(
            in: repositoryPath,
            args: ["rev-parse", "--verify", "refs/heads/\(parentBranch)"]
        )
        if hasLocalBranch {
            try runGitOrThrow(in: repositoryPath, args: ["checkout", parentBranch])
            return
        }

        let remoteRef = "refs/remotes/origin/\(parentBranch)"
        let (hasRemoteBranch, _) = runGitSync(
            in: repositoryPath,
            args: ["rev-parse", "--verify", remoteRef]
        )
        if hasRemoteBranch {
            try runGitOrThrow(
                in: repositoryPath,
                args: ["checkout", "-B", parentBranch, "origin/\(parentBranch)"]
            )
            return
        }

        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Selected branch '\(parentBranch)' was not found in the cloned repository."]
        )
    }

    // MARK: - Delete Workspace

    static func deleteWorkspace(_ workspace: Workspace) {
        if FileManager.default.fileExists(atPath: workspace.path) {
            try? FileManager.default.removeItem(atPath: workspace.path)
        }
    }

    // MARK: - Merge Workspace into Project

    static func mergeWorkspaceIntoProject(_ workspace: Workspace, projectPath: String) throws -> String {
        // 1. Check workspace has no uncommitted changes
        let (wsClean, wsStatus) = runGitSync(in: workspace.path, args: ["status", "--porcelain"])
        if wsClean {
            let trimmed = wsStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                throw MergeError.dirtyWorkspace(workspace.name)
            }
        }

        // 2. Check project has no uncommitted changes
        let (projClean, projStatus) = runGitSync(in: projectPath, args: ["status", "--porcelain"])
        if projClean {
            let trimmed = projStatus.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                throw MergeError.dirtyProject
            }
        }

        // 3. Checkout the source branch in the project
        let currentBranch = Git.shared.currentBranch(in: projectPath) ?? ""
        if currentBranch != workspace.parentBranch {
            let (checkoutOk, checkoutOutput) = runGitSync(in: projectPath, args: ["checkout", workspace.parentBranch])
            if !checkoutOk {
                throw MergeError.checkoutFailed(workspace.parentBranch, checkoutOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // 4. Add workspace as temp remote, fetch, merge
        let remoteName = "forge-\(workspace.name)"

        defer {
            // Always clean up the temp remote
            _ = runGitSync(in: projectPath, args: ["remote", "remove", remoteName])
        }

        try configurePathRemote(in: projectPath, name: remoteName, path: workspace.path)
        try runGitOrThrow(in: projectPath, args: ["fetch", remoteName, workspace.branch])

        let ref = "\(remoteName)/\(workspace.branch)"

        // Try fast-forward first to avoid unnecessary merge commits
        let (ffOk, _) = runGitSync(in: projectPath, args: ["merge", "--ff-only", ref])
        if ffOk {
            return "Merged '\(workspace.name)' into '\(workspace.parentBranch)'"
        }

        // Branches diverged — rebase workspace commits onto the project branch then fast-forward
        let tempBranch = "forge-rebase-\(workspace.name)"
        defer { _ = runGitSync(in: projectPath, args: ["branch", "-D", tempBranch]) }

        _ = runGitSync(in: projectPath, args: ["checkout", "-b", tempBranch, ref])
        let (rebaseOk, rebaseOutput) = runGitSync(in: projectPath, args: ["rebase", workspace.parentBranch])
        if !rebaseOk {
            _ = runGitSync(in: projectPath, args: ["rebase", "--abort"])
            _ = runGitSync(in: projectPath, args: ["checkout", workspace.parentBranch])
            throw MergeError.conflict(rebaseOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        _ = runGitSync(in: projectPath, args: ["checkout", workspace.parentBranch])
        let (mergeOk, mergeOutput) = runGitSync(in: projectPath, args: ["merge", "--ff-only", tempBranch])
        if !mergeOk {
            throw MergeError.conflict(mergeOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return "Merged '\(workspace.name)' into '\(workspace.parentBranch)'"
    }

    enum MergeError: LocalizedError {
        case dirtyWorkspace(String)
        case dirtyProject
        case checkoutFailed(String, String)
        case conflict(String)

        var errorDescription: String? {
            switch self {
            case let .dirtyWorkspace(name):
                "Workspace '\(name)' has uncommitted changes. Commit or stash them first."
            case .dirtyProject:
                "Project has uncommitted changes. Commit or stash them first."
            case let .checkoutFailed(branch, detail):
                "Failed to checkout '\(branch)': \(detail)"
            case let .conflict(detail):
                "Merge conflict — merge was aborted.\n\(detail)"
            }
        }
    }

    // MARK: - Rename Workspace

    static func renameWorkspace(_ workspace: Workspace, to newName: String) -> Workspace {
        var updated = workspace
        updated.name = newName
        return updated
    }

    // MARK: - Clone with Tiered Fallbacks

    private static func cloneProject(source: String, dest: String) throws -> CloneResult {
        guard !FileManager.default.fileExists(atPath: dest) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSLocalizedDescriptionKey: "Destination already exists: \(dest)"]
            )
        }

        // Check if source is a git worktree (.git is a file, not a directory)
        let gitPath = (source as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        let isWorktree = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) && !isDir.boolValue

        if !isWorktree {
            // Try APFS CoW clone via copyfile()
            if tryCopyfileClone(source: source, dest: dest) {
                return CloneResult(fullClone: false)
            }

            // Fallback: cp -c -R (macOS CoW copy)
            if tryCpCow(source: source, dest: dest) {
                return CloneResult(fullClone: false)
            }

            // Clean up any partial attempt
            try? FileManager.default.removeItem(atPath: dest)
        }

        // Final fallback: git clone
        try gitClone(source: source, dest: dest)
        return CloneResult(fullClone: true)
    }

    private static func tryCopyfileClone(source: String, dest: String) -> Bool {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        let result = source.withCString { src in
            dest.withCString { dst in
                copyfile(src, dst, nil, flags)
            }
        }
        return result == 0
    }

    private static func tryCpCow(source: String, dest: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-c", "-R", source, dest]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func gitClone(source: String, dest: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--local", source, dest]
        process.environment = ["GIT_TERMINAL_PROMPT": "0", "PATH": ShellEnvironment.resolvedPath]
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "git clone failed: \(stderr)"]
            )
        }

        fixRemoteOrigin(source: source, dest: dest)
    }

    private static func fixRemoteOrigin(source: String, dest: String) {
        let (success, output) = runGitSync(in: source, args: ["remote", "get-url", "origin"])
        let originalURL = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if success, !originalURL.isEmpty {
            _ = runGitSync(in: dest, args: ["remote", "set-url", "origin", originalURL])
        } else {
            _ = runGitSync(in: dest, args: ["remote", "remove", "origin"])
        }
    }

    // MARK: - Git Helpers

    private static func configurePathRemote(in repositoryPath: String, name: String, path: String) throws {
        let normalizedPath = (path as NSString).standardizingPath
        let (hasRemote, _) = runGitSync(in: repositoryPath, args: ["remote", "get-url", name])
        if hasRemote {
            try runGitOrThrow(in: repositoryPath, args: ["remote", "set-url", name, normalizedPath])
        } else {
            try runGitOrThrow(in: repositoryPath, args: ["remote", "add", name, normalizedPath])
        }
    }

    private static func runGitSync(in directory: String, args: [String]) -> (success: Bool, output: String) {
        let result = Git.shared.run(in: directory, args: args)
        return (result.success, result.output)
    }

    private static func runGitOrThrow(in directory: String, args: [String]) throws {
        _ = try Git.shared.runOrThrow(in: directory, args: args)
    }
}
